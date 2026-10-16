import { BusinessError } from '@kit.BasicServicesKit';
import { socket } from '@kit.NetworkKit';
import usbipNative from 'libusbip_native.so';
import {
  UsbConfigurationInfo,
  UsbDeviceHandle,
  UsbDeviceInfo,
  UsbInterfaceInfo,
  UsbIpServerEvent,
  UsbIpServerEventKind,
  UsbIpServerSettings,
  UsbIpServerStatus
} from '../usb/UsbModels';
import { UsbBackendError } from '../usb/UsbManagerBackend';
import { UsbBackendCoordinator } from '../usb/UsbBackendCoordinator';
import {
  MAX_DEVICE_COUNT,
  MAX_INTERFACES,
  OP_REP_DEVLIST,
  OP_REP_IMPORT,
  OP_REQ_DEVLIST,
  OP_REQ_IMPORT,
  USBIP_CMD_SUBMIT,
  USBIP_CMD_UNLINK,
  USBIP_DIR_IN,
  USBIP_NON_ISO_PACKETS,
  USBIP_RET_SUBMIT,
  USBIP_RET_UNLINK,
  USBIP_VERSION,
  UsbIpSubmitRequest,
  UsbIpUnlinkRequest,
  concatBytes,
  makeBasic,
  makeOpHeader,
  nextFrameLength,
  parseSetupPacket,
  parseSubmit,
  parseUnlink,
  readString,
  readU16,
  readU32,
  writeString,
  writeU16,
  writeU32
} from '../protocol/UsbIpWire';

type Listener = (event: UsbIpServerEvent) => void;
type PendingState = 'queued' | 'running' | 'complete';

interface ListenerSocketInfo {
  family: number;
  port: number;
  ipv6Only: number;
}

export type UsbHandleCloseDisposition = 'retain' | 'release' | 'quarantine';

export function classifyUsbHandleCloseDisposition(retainRequested: boolean, drained: boolean): UsbHandleCloseDisposition {
  if (!drained) return 'quarantine';
  return retainRequested ? 'retain' : 'release';
}

/** Resolves claim retention after an imported client has drained its transfers. */
export function shouldRetainSharedUsbHandle(serverRunning: boolean, deviceShared: boolean,
  explicitRetention: boolean | undefined): boolean {
  if (!deviceShared) return false;
  if (explicitRetention !== undefined) return explicitRetention;
  return serverRunning;
}

/** Explicit release wins if stop/unshare races a normal disconnect teardown. */
export function mergeUsbHandleRetention(current: boolean | undefined, requested: boolean | undefined): boolean | undefined {
  if (requested === undefined) return current;
  if (requested === false || current === undefined) return requested;
  return current;
}

export function isUsbDeviceExportable(device: UsbDeviceInfo): boolean {
  return device.shared && device.occupied && !device.closing;
}

export interface PendingTransfer {
  request: UsbIpSubmitRequest;
  endpointKey: string;
  state: PendingState;
  cancelled: boolean;
  control: boolean;
  cancel: (() => boolean) | undefined;
}

export type UnlinkDisposition = 'missing-or-completed' | 'non-cancellable-control' | 'cancel-queued' | 'cancel-active';

export interface UnlinkTransition {
  disposition: UnlinkDisposition;
  status: number;
  suppressSubmit: boolean;
}

/** The USB/IP basic header owns the transfer direction; transfer_flags is only advisory. */
export function usbIpSubmitDirection(request: UsbIpSubmitRequest): number {
  return request.direction;
}

export function classifyUnlinkTarget(pending: PendingTransfer | undefined): UnlinkDisposition {
  if (pending === undefined || pending.state === 'complete') return 'missing-or-completed';
  if (pending.state === 'queued') return 'cancel-queued';
  if (pending.control) return 'non-cancellable-control';
  return 'cancel-active';
}

/** Production state transition shared by network handling and protocol tests. */
export function beginUnlink(pendingBySequence: Map<number, PendingTransfer>, targetSequence: number): UnlinkTransition {
  const pending: PendingTransfer | undefined = pendingBySequence.get(targetSequence);
  const disposition: UnlinkDisposition = classifyUnlinkTarget(pending);
  if (disposition === 'missing-or-completed') return { disposition, status: 0, suppressSubmit: false };
  if (disposition === 'non-cancellable-control') return { disposition, status: USBIP_EOPNOTSUPP, suppressSubmit: false };
  if (disposition === 'cancel-queued' && pending !== undefined) {
    pending.cancelled = true;
    pending.state = 'complete';
    if (pendingBySequence.get(targetSequence) === pending) pendingBySequence.delete(targetSequence);
    return { disposition, status: USBIP_ECONNRESET, suppressSubmit: true };
  }
  return { disposition: 'cancel-active', status: 0, suppressSubmit: false };
}

/** Marks a successful usbCancelTransfer; the original RET_SUBMIT must stay suppressed. */
export function acceptActiveCancellation(pendingBySequence: Map<number, PendingTransfer>, targetSequence: number,
  pending: PendingTransfer): void {
  pending.cancelled = true;
  pending.state = 'complete';
  if (pendingBySequence.get(targetSequence) === pending) pendingBySequence.delete(targetSequence);
}

/** Completes the active UNLINK race using the backend's cancellation result. */
export function finishActiveUnlink(pendingBySequence: Map<number, PendingTransfer>, targetSequence: number,
  pending: PendingTransfer, cancellationAccepted: boolean): UnlinkTransition {
  if (!cancellationAccepted) {
    return { disposition: 'cancel-active', status: 0, suppressSubmit: false };
  }
  acceptActiveCancellation(pendingBySequence, targetSequence, pending);
  return { disposition: 'cancel-active', status: USBIP_ECONNRESET, suppressSubmit: true };
}

/** Called after async transfer completion. Returns whether its RET_SUBMIT may be written. */
export function completePendingTransfer(pendingBySequence: Map<number, PendingTransfer>, sequence: number,
  pending: PendingTransfer): boolean {
  pending.state = 'complete';
  if (pendingBySequence.get(sequence) === pending) pendingBySequence.delete(sequence);
  return !pending.cancelled;
}

/** Disconnect teardown used by the server and directly exercised by protocol tests. */
export function cancelAndClearPendingTransfers(pendingBySequence: Map<number, PendingTransfer>): void {
  pendingBySequence.forEach((pending: PendingTransfer) => {
    if (!pending.control) {
      try { pending.cancel?.(); } catch (_error) { }
    }
    pending.cancelled = true;
    pending.state = 'complete';
  });
  pendingBySequence.clear();
}

interface ConnectionState {
  socket: socket.TCPSocketConnection;
  bytes: Uint8Array;
  importedDeviceId: string;
  importedHandle: UsbDeviceHandle | undefined;
  closed: boolean;
  processing: boolean;
  sendTail: Promise<void>;
  pending: Map<number, PendingTransfer>;
  endpointTails: Map<string, Promise<void>>;
  idleTimer: number;
  closingPromise: Promise<void> | undefined;
  closeRetention: boolean | undefined;
}

const DEFAULT_SETTINGS: UsbIpServerSettings = {
  backendMode: 'usbManager',
  host: '0.0.0.0',
  port: 3240,
  autoRequestPermission: false,
  autoShare: false,
  maxClients: 4,
  forceClaim: false,
  retainClaimsOnStop: false
};

const USBIP_ECONNRESET: number = -104;
const USBIP_EOPNOTSUPP: number = -95;
const USBIP_EREMOTEIO: number = -121;
const URB_SHORT_NOT_OK: number = 0x0001;
const URB_ISO_ASAP: number = 0x0002;
const URB_NO_TRANSFER_DMA_MAP: number = 0x0004;
const URB_ZERO_PACKET: number = 0x0040;
const URB_NO_INTERRUPT: number = 0x0080;
const URB_FREE_BUFFER: number = 0x0100;
const URB_DIR_IN: number = 0x0200;
const TRANSFER_DRAIN_TIMEOUT_MS: number = 7000;

/**
 * USB/IP 1.1.1 exporter routed to the explicitly selected USB backend.
 * UI policy is deliberately explicit: listDevices never requests rights or shares devices.
 */
export class UsbIpServerService {
  private readonly backend: UsbBackendCoordinator = new UsbBackendCoordinator();
  private settings: UsbIpServerSettings = {
    backendMode: DEFAULT_SETTINGS.backendMode,
    host: DEFAULT_SETTINGS.host, port: DEFAULT_SETTINGS.port,
    autoRequestPermission: DEFAULT_SETTINGS.autoRequestPermission, autoShare: DEFAULT_SETTINGS.autoShare,
    maxClients: DEFAULT_SETTINGS.maxClients, forceClaim: DEFAULT_SETTINGS.forceClaim,
    retainClaimsOnStop: DEFAULT_SETTINGS.retainClaimsOnStop
  };
  private tcpServer: socket.TCPSocketServer | undefined = undefined;
  private connections: Map<number, ConnectionState> = new Map<number, ConnectionState>();
  private importedOwners: Map<string, number> = new Map<string, number>();
  private listeners: Set<Listener> = new Set<Listener>();
  private running: boolean = false;
  private lastError: string = '';
  private listenerFamilies: Array<'IPv4' | 'IPv6'> = [];
  private refreshTimer: number = -1;
  private deviceRefreshQueue: Promise<void> = Promise.resolve();

  async listDevices(): Promise<Array<UsbDeviceInfo>> {
    await this.backend.refreshMetadata();
    return this.overlayImportState(this.backend.listDevices());
  }

  async refreshDevices(): Promise<Array<UsbDeviceInfo>> {
    let snapshot: Array<UsbDeviceInfo> = [];
    const refreshWork: Promise<void> = this.deviceRefreshQueue.then(async (): Promise<void> => {
      snapshot = await this.refreshDevicesInternal();
    }, async (): Promise<void> => {
      snapshot = await this.refreshDevicesInternal();
    });
    this.deviceRefreshQueue = refreshWork.catch((): void => {});
    await refreshWork;
    return this.overlayImportState(snapshot);
  }

  async requestPermission(deviceId: string): Promise<boolean> {
    const granted: boolean = await this.backend.requestPermission(deviceId);
    this.publish('devices', granted ? (this.settings.backendMode === 'usbDdk' ?
      'DDK driver bound and initialized' : 'USB permission granted') : 'USB permission was not confirmed');
    return granted;
  }

  async share(deviceId: string): Promise<void> {
    this.backend.addShared(deviceId);
    try {
      const handle: UsbDeviceHandle = await this.backend.openForImport(deviceId, this.settings.forceClaim);
      if (handle.claimedInterfaces.length === 0) {
        throw new UsbBackendError('USB device has no interface that can be claimed; it was not marked shared', -95);
      }
    } catch (error) {
      await this.backend.removeShared(deviceId);
      await this.backend.closeDevice(deviceId);
      if (error instanceof UsbBackendError) throw error;
      if (error instanceof Error) throw new UsbBackendError(error.message, -5);
      throw new UsbBackendError('USB device share failed', -5);
    }
    this.publish('devices', `Shared USB device ${deviceId}`);
  }

  async unshare(deviceId: string): Promise<void> {
    let connectionError: Error | undefined = undefined;
    const owner: number | undefined = this.importedOwners.get(deviceId);
    if (owner !== undefined) {
      const state: ConnectionState | undefined = this.connections.get(owner);
      if (state !== undefined) {
        try { await this.closeConnection(state, 'USB device unshared', false); }
        catch (error) { connectionError = error instanceof Error ? error : new UsbBackendError('Client cleanup failed', -16); }
      }
    }
    await this.backend.removeShared(deviceId);
    try {
      await this.backend.closeDevice(deviceId);
    } catch (error) {
      if (error instanceof UsbBackendError) throw error;
      throw new UsbBackendError(error instanceof Error ? error.message : 'USB handle release failed', -16);
    }
    this.backend.clearDeviceClosing(deviceId);
    this.publish('devices', `Unshared USB device ${deviceId}`);
    if (connectionError !== undefined) this.lastError = connectionError.message;
  }

  async start(settings?: Partial<UsbIpServerSettings>): Promise<void> {
    if (settings !== undefined) {
      await this.updateSettings(settings);
    }
    if (this.running) {
      return;
    }
    const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    try {
      this.listenerFamilies = await this.listenForConfiguredHost(server);
    } catch (error) {
      try { await server.close(); } catch (_closeError) { }
      this.listenerFamilies = [];
      this.lastError = `USB/IP dual-stack listener setup failed: ${this.errorMessage(error as Object)}`;
      this.publish('error', this.lastError);
      throw new Error(this.lastError);
    }
    server.on('connect', (accepted: socket.TCPSocketConnection): void => {
      this.acceptConnection(accepted);
    });
    server.on('error', (error: BusinessError): void => {
      this.lastError = `TCP server error ${error.code}: ${error.message}`;
      this.publish('error', this.lastError);
    });
    this.tcpServer = server;
    this.running = true;
    this.lastError = '';
    const claimFailures: Array<string> = [];
    const sharedIds: Array<string> = this.backend.getSharedDeviceIds();
    for (let index: number = 0; index < sharedIds.length; index++) {
      try {
        const handle: UsbDeviceHandle = await this.backend.openForImport(sharedIds[index], this.settings.forceClaim);
        if (handle.claimedInterfaces.length === 0) {
          throw new UsbBackendError('Device has no claimable USB interface', -95);
        }
      } catch (error) {
        await this.backend.closeDevice(sharedIds[index]);
        claimFailures.push(`${sharedIds[index]}: ${this.errorMessage(error as Object)}`);
      }
    }
    if (claimFailures.length > 0) {
      this.lastError = `Server is listening, but could not claim selected devices: ${claimFailures.join('; ')}`;
    }
    this.refreshTimer = setInterval((): void => { void this.refreshDevicesAndPublish(); }, 3000);
    this.publish('status', 'USB/IP server started');
  }

  async stop(): Promise<void> {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
    this.running = false;
    const server: socket.TCPSocketServer | undefined = this.tcpServer;
    this.tcpServer = undefined;
    if (server !== undefined) {
      try { await server.close(); } catch (_error) { }
    }
    const clients: Array<ConnectionState> = Array.from(this.connections.values());
    let cleanupFailure: Error | undefined = undefined;
    for (let index: number = 0; index < clients.length; index++) {
      try {
        await this.closeConnection(clients[index], 'USB/IP server stopped', this.settings.retainClaimsOnStop);
      } catch (error) {
        if (cleanupFailure === undefined) {
          cleanupFailure = error instanceof Error ? error : new UsbBackendError('Client cleanup failed', -16);
        }
      }
    }
    if (!this.settings.retainClaimsOnStop) {
      try { await this.backend.closeAll(); }
      catch (error) {
        if (cleanupFailure === undefined) {
          cleanupFailure = error instanceof Error ? error : new UsbBackendError('USB handle cleanup failed', -16);
        }
      }
    }
    this.listenerFamilies = [];
    if (cleanupFailure !== undefined) {
      this.lastError = `USB/IP server stopped, but USB claims remain occupied: ${this.errorMessage(cleanupFailure as Object)}`;
      this.publish('error', this.lastError);
      this.publish('status', 'USB/IP server stopped with cleanup failures');
      return;
    }
    this.publish('status', 'USB/IP server stopped');
  }

  getSettings(): UsbIpServerSettings {
    const copy: UsbIpServerSettings = {
      backendMode: this.settings.backendMode,
      host: this.settings.host, port: this.settings.port,
      autoRequestPermission: this.settings.autoRequestPermission, autoShare: this.settings.autoShare,
      maxClients: this.settings.maxClients, forceClaim: this.settings.forceClaim,
      retainClaimsOnStop: this.settings.retainClaimsOnStop
    };
    return copy;
  }

  async updateSettings(settings: Partial<UsbIpServerSettings>): Promise<void> {
    const next: UsbIpServerSettings = {
      backendMode: settings.backendMode ?? this.settings.backendMode,
      host: settings.host ?? this.settings.host,
      port: settings.port ?? this.settings.port,
      autoRequestPermission: settings.autoRequestPermission ?? this.settings.autoRequestPermission,
      autoShare: settings.autoShare ?? this.settings.autoShare,
      maxClients: settings.maxClients ?? this.settings.maxClients,
      forceClaim: settings.forceClaim ?? this.settings.forceClaim,
      retainClaimsOnStop: settings.retainClaimsOnStop ?? this.settings.retainClaimsOnStop
    };
    if (this.running && (next.host !== this.settings.host || next.port !== this.settings.port)) {
      throw new Error('Stop the server before changing its bind address or port');
    }
    if (this.running && next.backendMode !== this.settings.backendMode) {
      throw new Error('Stop the server before changing the USB backend');
    }
    if (!this.running && next.backendMode !== this.settings.backendMode && this.backend.hasClosingDevices()) {
      throw new Error('Cannot change USB backend while a previous USB transfer is still draining');
    }
    if (!Number.isInteger(next.port) || next.port < 1 || next.port > 65535) {
      throw new Error('USB/IP port must be in the range 1 to 65535');
    }
    if (!Number.isInteger(next.maxClients) || next.maxClients < 1 || next.maxClients > 32) {
      throw new Error('Maximum client count must be in the range 1 to 32');
    }
    if (!this.running && next.backendMode !== this.settings.backendMode) {
      await this.backend.setMode(next.backendMode);
      this.importedOwners.clear();
    }
    this.settings = next;
    this.publish('status', 'USB/IP server settings updated');
  }

  getStatus(): UsbIpServerStatus {
    return {
      running: this.running,
      host: this.settings.host,
      port: this.settings.port,
      clientCount: this.importedOwners.size,
      sharedDeviceIds: this.running ?
        this.backend.listDevices().filter((item: UsbDeviceInfo): boolean => isUsbDeviceExportable(item))
          .map((item: UsbDeviceInfo): string => item.id) : [],
      occupiedDeviceIds: this.backend.listDevices().filter((item: UsbDeviceInfo): boolean => item.occupied)
        .map((item: UsbDeviceInfo): string => item.id),
      listenerFamilies: this.listenerFamilies.slice(),
      lastError: this.lastError
    };
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    listener({ kind: 'status', message: 'Current USB/IP server state', devices: this.currentDevices(), status: this.getStatus() });
    return (): void => { this.listeners.delete(listener); };
  }

  private publish(kind: UsbIpServerEventKind, message: string): void {
    const event: UsbIpServerEvent = { kind, message, devices: this.currentDevices(), status: this.getStatus() };
    this.listeners.forEach((listener: Listener) => {
      try { listener(event); } catch (_error) { }
    });
  }

  private async listenForConfiguredHost(server: socket.TCPSocketServer): Promise<Array<'IPv4' | 'IPv6'>> {
    const host: string = this.settings.host.trim();
    if (host === '0.0.0.0' || host === '::' || host.length === 0) {
      const ipv6: ListenerSocketInfo = await this.listenAndVerify(server, '::', 2);
      if (ipv6.ipv6Only === 0) return ['IPv4', 'IPv6'];
      if (ipv6.ipv6Only !== 1) {
        throw new Error('Could not verify whether the IPv6 listener also accepts IPv4 connections');
      }
      await this.listenAndVerify(server, '0.0.0.0', 1);
      return ['IPv4', 'IPv6'];
    }
    const family: number = host.includes(':') ? 2 : 1;
    await this.listenAndVerify(server, host, family);
    return [family === 2 ? 'IPv6' : 'IPv4'];
  }

  private async listenAndVerify(server: socket.TCPSocketServer, addressText: string,
    family: number): Promise<ListenerSocketInfo> {
    await server.listen({ address: addressText, port: this.settings.port, family });
    const fd: number = await server.getSocketFd();
    if (fd < 0) throw new Error(`Socket API returned invalid descriptor for ${addressText}`);
    const actual: ListenerSocketInfo = usbipNative.getListenerSocketInfo(fd);
    if (actual.family !== (family === 1 ? 4 : 6) || actual.port !== this.settings.port) {
      throw new Error(`Requested ${addressText}:${this.settings.port}, but system bound family=${actual.family} port=${actual.port}`);
    }
    return actual;
  }

  private acceptConnection(client: socket.TCPSocketConnection): void {
    if (!this.running || this.connections.size >= this.settings.maxClients) {
      void client.close();
      return;
    }
    const state: ConnectionState = {
      socket: client, bytes: new Uint8Array(0), importedDeviceId: '', importedHandle: undefined,
      closed: false, processing: false, sendTail: Promise.resolve(), pending: new Map<number, PendingTransfer>(),
      endpointTails: new Map<string, Promise<void>>(),
      idleTimer: -1,
      closingPromise: undefined,
      closeRetention: undefined
    };
    state.idleTimer = setTimeout((): void => {
      if (state.importedHandle === undefined) void this.closeConnection(state, 'USB/IP handshake timed out');
    }, 5000);
    this.connections.set(client.clientId, state);
    client.on('message', (message: socket.SocketMessageInfo): void => {
      this.appendBytes(state, new Uint8Array(message.message));
    });
    client.on('close', (): void => { void this.closeConnection(state, 'USB/IP client disconnected'); });
    client.on('error', (error: BusinessError): void => {
      this.lastError = `Client ${client.clientId}: ${error.code} ${error.message}`;
      void this.closeConnection(state, this.lastError);
    });
    this.publish('client', `TCP client ${client.clientId} connected`);
  }

  private appendBytes(state: ConnectionState, bytes: Uint8Array): void {
    if (state.closed) return;
    if (state.bytes.length + bytes.length > 32 * 1024 * 1024) {
      void this.closeConnection(state, 'Client stream exceeded the 32 MiB frame buffer limit');
      return;
    }
    state.bytes = concatBytes(state.bytes, bytes);
    this.processFrames(state);
  }

  private processFrames(state: ConnectionState): void {
    if (state.processing || state.closed) return;
    state.processing = true;
    void (async (): Promise<void> => {
      try {
        while (!state.closed) {
          const frameLength: number = nextFrameLength(state.bytes);
          if (frameLength === 0) break;
          const frame: Uint8Array = state.bytes.slice(0, frameLength);
          state.bytes = state.bytes.slice(frameLength);
          await this.handleFrame(state, frame);
        }
      } catch (error) {
        this.lastError = `USB/IP client protocol error: ${this.errorMessage(error as Object)}`;
        this.publish('error', this.lastError);
        await this.closeConnection(state, this.lastError);
      } finally {
        state.processing = false;
      }
    })();
  }

  private async handleFrame(state: ConnectionState, frame: Uint8Array): Promise<void> {
    if (frame.length < 4) throw new Error('Short USB/IP frame');
    const command: number = readU32(frame, 0);
    if (command === USBIP_CMD_SUBMIT) {
      if (state.importedHandle === undefined) throw new Error('SUBMIT received before successful IMPORT');
      const request: UsbIpSubmitRequest = parseSubmit(frame);
      if (state.pending.size >= 128) throw new Error('Too many in-flight requests on one client');
      let pendingBytes: number = 0;
      state.pending.forEach((item: PendingTransfer) => { pendingBytes += item.request.transferLength; });
      if (pendingBytes + request.transferLength > 32 * 1024 * 1024) throw new Error('In-flight USB/IP request bytes exceed 32 MiB');
      if (request.devid !== ((state.importedHandle.info.busNum << 16) | state.importedHandle.info.devAddress)) {
        throw new Error('SUBMIT device id does not match imported device');
      }
      this.queueSubmit(state, request);
      return;
    }
    if (command === USBIP_CMD_UNLINK) {
      if (state.importedHandle === undefined) throw new Error('UNLINK received before successful IMPORT');
      this.unlink(state, parseUnlink(frame));
      return;
    }
    const opVersion: number = readU16(frame, 0);
    const opCommand: number = readU16(frame, 2);
    if (opVersion !== USBIP_VERSION) throw new Error(`Unsupported USB/IP version 0x${opVersion.toString(16)}`);
    if (state.importedHandle !== undefined) throw new Error('Only SUBMIT and UNLINK are valid after IMPORT');
    if (opCommand === OP_REQ_DEVLIST) {
      await this.send(state, this.buildDeviceListReplyFor(this.backend.listDevices()));
      await this.closeConnection(state, 'USB/IP device-list request completed');
      return;
    }
    if (opCommand === OP_REQ_IMPORT) {
      await this.importDevice(state, readString(frame, 8, 32));
      return;
    }
    throw new Error(`Unsupported operation 0x${opCommand.toString(16)}`);
  }

  private async importDevice(state: ConnectionState, busId: string): Promise<void> {
    const device: UsbDeviceInfo | undefined = this.backend.listDevices().find(
      (item: UsbDeviceInfo): boolean => item.busId === busId && isUsbDeviceExportable(item)
    );
    if (device === undefined) {
      await this.send(state, makeOpHeader(OP_REP_IMPORT, 1, 0));
      await this.closeConnection(state, `Import rejected: ${busId} is not shared`);
      return;
    }
    const owner: number | undefined = this.importedOwners.get(device.id);
    if (owner !== undefined && owner !== state.socket.clientId) {
      await this.send(state, makeOpHeader(OP_REP_IMPORT, 1, 0));
      await this.closeConnection(state, `Import rejected: ${busId} is already imported`);
      return;
    }
    if (this.importedOwners.size >= this.settings.maxClients) {
      await this.send(state, makeOpHeader(OP_REP_IMPORT, 1, 0));
      await this.closeConnection(state, 'Import rejected: server client limit reached');
      return;
    }
    try {
      const handle: UsbDeviceHandle = await this.backend.openForImport(device.id, this.settings.forceClaim);
      this.importedOwners.set(device.id, state.socket.clientId);
      state.importedDeviceId = device.id;
      state.importedHandle = handle;
      if (state.idleTimer >= 0) {
        clearTimeout(state.idleTimer);
        state.idleTimer = -1;
      }
      await this.send(state, this.buildImportReply(handle.info));
      this.publish('client', `Client ${state.socket.clientId} imported ${device.busId}`);
    } catch (error) {
      const backendError: UsbBackendError = error as UsbBackendError;
      this.lastError = `USB import failed: ${this.errorMessage(error as Object)}`;
      this.publish('error', this.lastError);
      await this.send(state, makeOpHeader(OP_REP_IMPORT, 1, 0));
      await this.closeConnection(state, backendError.message);
    }
  }

  buildDeviceListReplyFor(devices: Array<UsbDeviceInfo>): Uint8Array {
    const exported: Array<UsbDeviceInfo> = devices.filter(
      (item: UsbDeviceInfo): boolean => isUsbDeviceExportable(item)
    );
    if (exported.length > MAX_DEVICE_COUNT) throw new Error(`Too many exported devices (${exported.length})`);
    let result: Uint8Array = makeOpHeader(OP_REP_DEVLIST, 0, 4);
    writeU32(result, 8, exported.length);
    exported.forEach((device: UsbDeviceInfo) => {
      const interfaces: Array<UsbInterfaceInfo> = this.activeInterfaces(device);
      if (interfaces.length > MAX_INTERFACES) throw new Error(`Device ${device.busId} has too many interfaces`);
      const record: Uint8Array = new Uint8Array(312 + interfaces.length * 4);
      writeString(record, 0, 256, device.path);
      writeString(record, 256, 32, device.busId);
      writeU32(record, 288, device.busNum);
      writeU32(record, 292, device.devAddress);
      writeU32(record, 296, device.speed);
      writeU16(record, 300, device.vendorId);
      writeU16(record, 302, device.productId);
      writeU16(record, 304, this.bcdDevice(device.version));
      record[306] = device.deviceClass & 0xff;
      record[307] = device.deviceSubClass & 0xff;
      record[308] = device.deviceProtocol & 0xff;
      record[309] = device.configurations.length > 0 ? device.configurations[0].id & 0xff : 0;
      record[310] = device.configurations.length & 0xff;
      record[311] = interfaces.length & 0xff;
      interfaces.forEach((iface: UsbInterfaceInfo, index: number) => {
        const offset: number = 312 + index * 4;
        record[offset] = iface.clazz & 0xff;
        record[offset + 1] = iface.subClass & 0xff;
        record[offset + 2] = iface.protocol & 0xff;
      });
      result = concatBytes(result, record);
    });
    return result;
  }

  buildImportReply(device: UsbDeviceInfo): Uint8Array {
    const data: Uint8Array = makeOpHeader(OP_REP_IMPORT, 0, 312);
    writeString(data, 8, 256, device.path);
    writeString(data, 264, 32, device.busId);
    writeU32(data, 296, device.busNum);
    writeU32(data, 300, device.devAddress);
    writeU32(data, 304, device.speed);
    writeU16(data, 308, device.vendorId);
    writeU16(data, 310, device.productId);
    writeU16(data, 312, this.bcdDevice(device.version));
    data[314] = device.deviceClass & 0xff;
    data[315] = device.deviceSubClass & 0xff;
    data[316] = device.deviceProtocol & 0xff;
    data[317] = device.configurations.length > 0 ? device.configurations[0].id & 0xff : 0;
    data[318] = device.configurations.length & 0xff;
    data[319] = this.activeInterfaces(device).length & 0xff;
    return data;
  }

  private activeInterfaces(device: UsbDeviceInfo): Array<UsbInterfaceInfo> {
    const config: UsbConfigurationInfo | undefined = device.configurations[0];
    if (config === undefined) return [];
    const byId: Map<number, UsbInterfaceInfo> = new Map<number, UsbInterfaceInfo>();
    config.interfaces.forEach((iface: UsbInterfaceInfo) => {
      if (!byId.has(iface.id) || iface.alternateSetting === 0) byId.set(iface.id, iface);
    });
    return Array.from(byId.values()).sort((a: UsbInterfaceInfo, b: UsbInterfaceInfo): number => a.id - b.id);
  }

  private bcdDevice(version: string): number {
    const normalized: string = version.replace(/[^0-9.]/g, '');
    const parts: Array<string> = normalized.split('.');
    if (parts.length === 1) return 0;
    const major: number = Math.min(99, Number.parseInt(parts[0], 10) || 0);
    const minor: number = Math.min(99, Number.parseInt(parts[1], 10) || 0);
    const patch: number = parts.length > 2 ? Math.min(9, Number.parseInt(parts[2], 10) || 0) : 0;
    return (((Math.floor(major / 10) & 0xf) << 12) | ((major % 10) << 8) | ((Math.floor(minor / 10) & 0xf) << 4) | (minor % 10)) + patch;
  }

  private queueSubmit(state: ConnectionState, request: UsbIpSubmitRequest): void {
    if (state.pending.has(request.seqnum)) throw new Error(`Duplicate USB/IP sequence number ${request.seqnum}`);
    const isControl: boolean = request.endpoint === 0;
    const endpointKey: string = isControl ? 'control' : `${request.direction}:${request.endpoint}`;
    const pending: PendingTransfer = { request, endpointKey, state: 'queued', cancelled: false, control: isControl, cancel: undefined };
    state.pending.set(request.seqnum, pending);
    const previous: Promise<void> = state.endpointTails.get(endpointKey) ?? Promise.resolve();
    const task: Promise<void> = previous.then(async (): Promise<void> => {
      if (pending.cancelled || state.closed) return;
      pending.state = 'running';
      try {
        const reply: Uint8Array = await this.executeSubmit(state, pending);
        const shouldReply: boolean = completePendingTransfer(state.pending, request.seqnum, pending);
        if (shouldReply && !state.closed) await this.send(state, reply);
      } catch (error) {
        const shouldReply: boolean = completePendingTransfer(state.pending, request.seqnum, pending);
        if (shouldReply && !state.closed) {
          const err: UsbBackendError = error as UsbBackendError;
          await this.send(state, this.buildSubmitReply(request, err.status ?? -5, 0, new Uint8Array(0)));
        }
      } finally {
      }
    });
    state.endpointTails.set(endpointKey, task.catch((): void => {}));
  }

  private async executeSubmit(state: ConnectionState, pending: PendingTransfer): Promise<Uint8Array> {
    const request: UsbIpSubmitRequest = pending.request;
    const direction: number = usbIpSubmitDirection(request);
    const handle: UsbDeviceHandle | undefined = state.importedHandle;
    if (handle === undefined) return this.buildSubmitReply(request, -19, 0, new Uint8Array(0));
    if (direction !== 0 && direction !== 1) return this.buildSubmitReply(request, -22, 0, new Uint8Array(0));
    if (request.numberOfPackets !== 0 && request.numberOfPackets !== USBIP_NON_ISO_PACKETS) {
      return this.buildSubmitReply(request, -95, 0, new Uint8Array(0));
    }
    if ((request.transferFlags & URB_ISO_ASAP) !== 0) {
      return this.buildSubmitReply(request, USBIP_EOPNOTSUPP, 0, new Uint8Array(0));
    }
    const unsupportedFlags: number = request.transferFlags & ~(URB_SHORT_NOT_OK | URB_NO_TRANSFER_DMA_MAP |
      URB_ZERO_PACKET | URB_NO_INTERRUPT | URB_FREE_BUFFER | URB_DIR_IN);
    if (unsupportedFlags !== 0) return this.buildSubmitReply(request, USBIP_EOPNOTSUPP, 0, new Uint8Array(0));
    // The USB/IP basic header direction is authoritative. Client URB direction flags
    // may be absent or stale (usbip-win2 itself repairs them from the endpoint/setup).
    // NO_TRANSFER_DMA_MAP and NO_INTERRUPT are Linux host scheduling/memory hints. FREE_BUFFER
    // describes the peer's URB ownership only; none has a usbManager equivalent or changes USB I/O.
    if (request.endpoint === 0) {
      if ((request.transferFlags & URB_ZERO_PACKET) !== 0) {
        return this.buildSubmitReply(request, USBIP_EOPNOTSUPP, 0, new Uint8Array(0));
      }
      const length: number = request.transferLength;
      const setup = parseSetupPacket(request.setup);
      const controlDirection: number = setup.requestType & 0x80 ? USBIP_DIR_IN : 0;
      if (length !== setup.length) return this.buildSubmitReply(request, -22, 0, new Uint8Array(0));
      if (direction !== controlDirection) return this.buildSubmitReply(request, -22, 0, new Uint8Array(0));
      const requestType: number = setup.requestType;
      const requestCode: number = setup.request;
      const value: number = setup.value;
      const index: number = setup.index;
      if ((requestType & 0x7f) === 0 && requestCode === 9) {
        const result: number = await this.backend.setConfiguration(handle, value, this.settings.forceClaim);
        return this.buildSubmitReply(request, result === 0 ? 0 : result, 0, new Uint8Array(0));
      }
      if ((requestType & 0x7f) === 1 && requestCode === 11) {
        const result: number = await this.backend.setAlternate(handle, index, value);
        return this.buildSubmitReply(request, result === 0 ? 0 : result, 0, new Uint8Array(0));
      }
      const result = await this.backend.controlTransfer(handle, request.setup, request.payload, length,
        controlDirection, 5000);
      if ((request.transferFlags & URB_SHORT_NOT_OK) !== 0 && result.actualLength < length) {
        const shortData: Uint8Array = controlDirection === USBIP_DIR_IN ? result.data.slice(0, result.actualLength) : new Uint8Array(0);
        return this.buildSubmitReply(request, USBIP_EREMOTEIO, result.actualLength, shortData);
      }
      return this.buildSubmitReply(request, 0, result.actualLength, controlDirection === USBIP_DIR_IN ? result.data.slice(0, result.actualLength) : new Uint8Array(0));
    }
    const transfer = this.backend.startTransfer(handle, request.endpoint, direction, request.payload,
      request.transferLength, 0, request.transferFlags);
    pending.cancel = transfer.cancel;
    const result = await transfer.promise;
    let status: number = this.usbTransferStatus(result.status);
    if (status === 0 && (request.transferFlags & URB_SHORT_NOT_OK) !== 0 && result.actualLength < request.transferLength) {
      status = USBIP_EREMOTEIO;
    }
    const data: Uint8Array = direction === USBIP_DIR_IN ? result.data.slice(0, result.actualLength) : new Uint8Array(0);
    return this.buildSubmitReply(request, status, result.actualLength, data);
  }

  private unlink(state: ConnectionState, request: UsbIpUnlinkRequest): void {
    const pending: PendingTransfer | undefined = state.pending.get(request.targetSeqnum);
    const transition: UnlinkTransition = beginUnlink(state.pending, request.targetSeqnum);
    if (transition.disposition !== 'cancel-active') {
      void this.send(state, this.buildUnlinkReply(request.seqnum, transition.status));
      return;
    }
    if (pending === undefined) {
      void this.send(state, this.buildUnlinkReply(request.seqnum, 0));
      return;
    }
    try {
      const cancellationAccepted: boolean = pending.cancel !== undefined && pending.cancel();
      const completed: UnlinkTransition = finishActiveUnlink(state.pending, request.targetSeqnum, pending, cancellationAccepted);
      void this.send(state, this.buildUnlinkReply(request.seqnum, completed.status));
    } catch (_error) {
      // Request may have completed between the lookup and cancel. Keep its RET_SUBMIT and report status 0.
      void this.send(state, this.buildUnlinkReply(request.seqnum, 0));
    }
  }

  buildSubmitReply(request: UsbIpSubmitRequest, status: number, actualLength: number, payload: Uint8Array): Uint8Array {
    const header: Uint8Array = makeBasic(USBIP_RET_SUBMIT, request.seqnum);
    writeU32(header, 20, status >>> 0);
    writeU32(header, 24, actualLength);
    writeU32(header, 28, request.startFrame);
    writeU32(header, 32, USBIP_NON_ISO_PACKETS);
    writeU32(header, 36, 0);
    return payload.length > 0 ? concatBytes(header, payload) : header;
  }

  buildUnlinkReply(seqnum: number, status: number): Uint8Array {
    const header: Uint8Array = makeBasic(USBIP_RET_UNLINK, seqnum);
    writeU32(header, 20, status >>> 0);
    return header;
  }

  private usbTransferStatus(status: number): number {
    if (status === 0) return 0;
    if (status === 2) return -110;
    if (status === 3) return -104;
    if (status === 4) return -32;
    if (status === 5) return -19;
    if (status === 6) return -75;
    return -5;
  }

  private async send(state: ConnectionState, bytes: Uint8Array): Promise<void> {
    const task: Promise<void> = state.sendTail.then(async (): Promise<void> => {
      if (state.closed) return;
      const exact: Uint8Array = new Uint8Array(bytes.length);
      exact.set(bytes);
      await state.socket.send({ data: exact.buffer });
    });
    state.sendTail = task.catch((error: Object): void => {
      this.lastError = `TCP send failed: ${this.errorMessage(error)}`;
      void this.closeConnection(state, this.lastError);
    });
    await task;
  }

  private closeConnection(state: ConnectionState, reason: string,
    retainDeviceHandle: boolean | undefined = undefined): Promise<void> {
    state.closeRetention = mergeUsbHandleRetention(state.closeRetention, retainDeviceHandle);
    if (state.closingPromise !== undefined) return state.closingPromise;
    const closePromise: Promise<void> = Promise.resolve().then(async (): Promise<void> => {
      await this.closeConnectionInternal(state, reason);
    });
    state.closingPromise = closePromise;
    return closePromise;
  }

  private async closeConnectionInternal(state: ConnectionState, reason: string): Promise<void> {
    if (state.closed) return;
    state.closed = true;
    if (state.idleTimer >= 0) {
      clearTimeout(state.idleTimer);
      state.idleTimer = -1;
    }
    if (state.importedDeviceId.length > 0) this.backend.markDeviceClosing(state.importedDeviceId);
    cancelAndClearPendingTransfers(state.pending);
    const drained: boolean = await this.waitForTransferDrain(state);
    let cleanupError: Error | undefined = undefined;
    if (state.importedDeviceId.length > 0) {
      const deviceId: string = state.importedDeviceId;
      const retainDeviceHandle: boolean = shouldRetainSharedUsbHandle(this.running, this.backend.isShared(deviceId),
        state.closeRetention);
      const disposition: UsbHandleCloseDisposition = classifyUsbHandleCloseDisposition(retainDeviceHandle, drained);
      this.importedOwners.delete(deviceId);
      if (disposition !== 'quarantine') {
        if (disposition === 'release') {
          try {
            await this.backend.closeDevice(deviceId);
            this.backend.clearDeviceClosing(deviceId);
          } catch (error) {
            cleanupError = error instanceof Error ? error : new UsbBackendError('USB handle release failed', -16);
            this.lastError = `USB device ${deviceId} release failed; its claim remains occupied: ${this.errorMessage(cleanupError as Object)}`;
            this.publish('error', this.lastError);
          }
        } else {
          this.backend.clearDeviceClosing(deviceId);
        }
      } else {
        this.lastError = `USB device ${deviceId} is quarantined until its previous transfer completes; its claim will not be reused.`;
        const tails: Array<Promise<void>> = Array.from(state.endpointTails.values());
        void Promise.all(tails).then(async (): Promise<void> => {
          try {
            await this.backend.closeDevice(deviceId);
            this.backend.clearDeviceClosing(deviceId);
            this.publish('devices', `USB device ${deviceId} transfer drain completed and its claim was released`);
          } catch (error) {
            this.lastError = `USB device ${deviceId} release failed after transfer drain: ${this.errorMessage(error as Object)}`;
            this.publish('error', this.lastError);
          }
        });
      }
      state.importedDeviceId = '';
      state.importedHandle = undefined;
    }
    try { await state.socket.close(); } catch (_error) { }
    this.connections.delete(state.socket.clientId);
    this.publish('client', reason);
    if (cleanupError !== undefined) throw cleanupError;
  }

  private async waitForTransferDrain(state: ConnectionState): Promise<boolean> {
    const tails: Array<Promise<void>> = Array.from(state.endpointTails.values());
    if (tails.length === 0) return true;
    return await new Promise<boolean>((resolve): void => {
      let settled: boolean = false;
      const timer: number = setTimeout((): void => {
        if (settled) return;
        settled = true;
        resolve(false);
      }, TRANSFER_DRAIN_TIMEOUT_MS);
      void Promise.all(tails).then((): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(true);
      });
    });
  }

  private async refreshDevicesAndPublish(): Promise<void> {
    await this.refreshDevices();
    this.publish('devices', 'USB device snapshot refreshed');
  }

  private async refreshDevicesInternal(): Promise<Array<UsbDeviceInfo>> {
    await this.backend.refreshMetadata();
    const removed: Array<string> = await this.backend.pruneMissingDevices();
    for (let index: number = 0; index < removed.length; index++) {
      const deviceId: string = removed[index];
      const owner: number | undefined = this.importedOwners.get(deviceId);
      if (owner !== undefined) {
        const state: ConnectionState | undefined = this.connections.get(owner);
        if (state !== undefined) await this.closeConnection(state, `USB device ${deviceId} disconnected`);
        else await this.backend.closeDevice(deviceId);
      } else {
        await this.backend.closeDevice(deviceId);
      }
    }
    return this.backend.listDevices();
  }

  private currentDevices(): Array<UsbDeviceInfo> {
    return this.overlayImportState(this.backend.listDevices());
  }

  private overlayImportState(devices: Array<UsbDeviceInfo>): Array<UsbDeviceInfo> {
    devices.forEach((device: UsbDeviceInfo): void => {
      device.imported = this.importedOwners.has(device.id);
      device.closing = this.backend.isDeviceClosing(device.id);
      device.available = !device.closing;
    });
    return devices;
  }

  private errorMessage(error: Object): string {
    const item: BusinessError = error as BusinessError;
    if (item.message !== undefined) return item.message;
    return JSON.stringify(error);
  }
}

export const UsbIpServer: UsbIpServerService = new UsbIpServerService();
