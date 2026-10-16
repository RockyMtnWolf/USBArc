import { BusinessError } from '@kit.BasicServicesKit';
import { deviceManager } from '@kit.DriverDevelopmentKit';
import { rpc } from '@kit.IPCKit';

const DDK_RPC_CODE: number = 0x5542;
const MAX_RPC_JSON_CHARS: number = 38000;
export const MAX_DDK_RPC_TRANSFER_BYTES: number = 8000;
export const MAX_DDK_CONTROL_TRANSFER_BYTES: number = 1024;
const RPC_WAIT_SECONDS: number = 35;

export interface DdkTransferExpectation {
  isInput: boolean;
  maxLength: number;
}

export interface DdkSystemDeviceInfo {
  deviceId: number;
  vendorId: number;
  productId: number;
  description: string;
}

export interface DdkDeviceDescriptor {
  id: string;
  bytes: Array<number>;
  vendorId: number;
  productId: number;
  deviceClass: number;
  deviceSubClass: number;
  deviceProtocol: number;
  bcdUsb: number;
  bcdDevice: number;
  maxPacketSize0: number;
  configurationCount: number;
}

export interface DdkActiveConfiguration {
  configurationValue: number;
}

export interface DdkConfigurationDescriptor {
  configurationValue: number;
  attributes: number;
  maxPower: number;
  interfaceCount: number;
  bytes: Array<number>;
}

export interface DdkTransferResult {
  status: number;
  actualLength: number;
  data: Array<number>;
}

interface DdkRpcRequest {
  operation: string;
  deviceId: string;
  interfaceNumber: number;
  handle: string;
  alternateSetting: number;
  configurationIndex: number;
  endpointAddress: number;
  timeoutMs: number;
  setup: Array<number>;
  data: Array<number>;
}

interface DdkRpcReply {
  status: number;
  error?: string;
  initialized?: boolean;
  resourcesReleased?: boolean;
  value?: Object;
  actualLength?: number;
  data?: Array<number>;
}

export type DdkDriverHealth = 'healthy' | 'released' | 'unavailable';
export type DdkReleasedCleanup = 'released-unbound' | 'released-still-bound' | 'not-released';

export function classifyDdkDriverHealth(status: number, initialized: boolean | undefined,
  resourcesReleased: boolean | undefined): DdkDriverHealth {
  if (status === 0 && initialized === true) return 'healthy';
  if (initialized === false && resourcesReleased === true) return 'released';
  return 'unavailable';
}

interface DdkBinding {
  systemDevice: DdkSystemDeviceInfo;
  driver: deviceManager.RemoteDeviceDriver;
  deathRecipient: rpc.DeathRecipient;
  claimTokens: Set<string>;
}

export class DdkDriverClientError extends Error {
  status: number;
  usbErrno: number;

  constructor(message: string, status: number, usbErrno: number) {
    super(message);
    this.status = status;
    this.usbErrno = usbErrno;
  }
}

export function mapDdkUsbErrno(status: number): number {
  if (status === -90 || status === -75 || status === -32 || status === -22 || status === -19 ||
    status === -16 || status === -13 || status === -5 || status === -95 || status === -104 ||
    status === -110 || status === -121) return status;
  if (status === 201 || status === 26300002) return -13;
  if (status === 401) return -22;
  if (status === 26300003 || status === 27400002) return -19;
  if (status === 27400004) return -110;
  if (status === 27400001) return -12;
  if (status === 27400003) return -5;
  return -5;
}

export function normalizeDdkTimeout(timeoutMs: number): number {
  if (!Number.isFinite(timeoutMs) || timeoutMs < 0) return 10000;
  if (timeoutMs === 0) return 10000;
  return Math.max(1, Math.min(30000, Math.floor(timeoutMs)));
}

export function getDdkTransferExpectation(operation: string, endpointAddress: number,
  setup: Array<number>, data: Array<number>): DdkTransferExpectation {
  if (operation === 'controlTransfer' || operation === 'claimedControlTransfer') {
    if (setup.length !== 8 || setup.some((byte: number): boolean =>
      !Number.isInteger(byte) || byte < 0 || byte > 255)) {
      throw new DdkDriverClientError('USB control setup must contain 8 valid bytes', -22, -22);
    }
    const length: number = setup[6] | (setup[7] << 8);
    const isInput: boolean = (setup[0] & 0x80) !== 0;
    if (length > MAX_DDK_CONTROL_TRANSFER_BYTES || (isInput ? data.length < length : data.length !== length)) {
      throw new DdkDriverClientError('USB control payload does not cover wLength', -22, -22);
    }
    return { isInput, maxLength: length };
  }
  if (operation !== 'pipeTransfer' || !Number.isInteger(endpointAddress) || endpointAddress < 0 ||
    endpointAddress > 255 || (endpointAddress & 0x70) !== 0 || (endpointAddress & 0x0f) === 0) {
    throw new DdkDriverClientError('USB pipe endpoint address is invalid', -22, -22);
  }
  return { isInput: (endpointAddress & 0x80) !== 0, maxLength: data.length };
}

export function validateDdkTransferRequest(operation: string, endpointAddress: number, setup: Array<number>,
  data: Array<number>): DdkTransferExpectation {
  if (data.length > MAX_DDK_RPC_TRANSFER_BYTES) {
    throw new DdkDriverClientError(`DDK RPC transfer exceeds ${MAX_DDK_RPC_TRANSFER_BYTES}-byte limit`, -90, -90);
  }
  for (let index: number = 0; index < data.length; index++) {
    if (!Number.isInteger(data[index]) || data[index] < 0 || data[index] > 255) {
      throw new DdkDriverClientError('USB transfer data contains an invalid byte', -22, -22);
    }
  }
  return getDdkTransferExpectation(operation, endpointAddress, setup, data);
}

export function isValidDdkTransferResult(expectation: DdkTransferExpectation, actualLength: number,
  responseData: Array<number>): boolean {
  if (!Number.isInteger(actualLength) || actualLength < 0 || actualLength > expectation.maxLength) return false;
  for (let index: number = 0; index < responseData.length; index++) {
    if (!Number.isInteger(responseData[index]) || responseData[index] < 0 || responseData[index] > 255) return false;
  }
  return expectation.isInput ? responseData.length === actualLength : responseData.length === 0;
}

function toSystemDeviceInfo(device: Readonly<deviceManager.Device>): DdkSystemDeviceInfo | undefined {
  if (device.busType !== deviceManager.BusType.USB) return undefined;
  const usbDevice: deviceManager.USBDevice = device as deviceManager.USBDevice;
  return {
    deviceId: usbDevice.deviceId,
    vendorId: usbDevice.vendorId,
    productId: usbDevice.productId,
    description: usbDevice.description
  };
}

function makeRequest(operation: string): DdkRpcRequest {
  return {
    operation,
    deviceId: '',
    interfaceNumber: 0,
    handle: '',
    alternateSetting: 0,
    configurationIndex: 0,
    endpointAddress: 0,
    timeoutMs: 0,
    setup: [],
    data: []
  };
}

export class DdkDriverClient {
  private bindings: Map<number, DdkBinding> = new Map<number, DdkBinding>();
  private disconnectListeners: Set<(systemDeviceId: number) => void> = new Set<(systemDeviceId: number) => void>();

  listSystemDevices(): Array<DdkSystemDeviceInfo> {
    try {
      const result: Array<DdkSystemDeviceInfo> = [];
      deviceManager.queryDevices(deviceManager.BusType.USB).forEach((device: Readonly<deviceManager.Device>): void => {
        const mapped: DdkSystemDeviceInfo | undefined = toSystemDeviceInfo(device);
        if (mapped !== undefined) result.push(mapped);
      });
      return result;
    } catch (error) {
      throw this.fromPlatformError('query USB devices', error as Object);
    }
  }

  subscribeDisconnect(listener: (systemDeviceId: number) => void): () => void {
    this.disconnectListeners.add(listener);
    return (): void => { this.disconnectListeners.delete(listener); };
  }

  async checkHealth(systemDeviceId: number): Promise<DdkDriverHealth> {
    const response: DdkRpcReply = await this.call(systemDeviceId, makeRequest('health'));
    return classifyDdkDriverHealth(response.status, response.initialized, response.resourcesReleased);
  }

  async cleanupReleasedBinding(systemDeviceId: number): Promise<DdkReleasedCleanup> {
    const health: DdkDriverHealth = await this.checkHealth(systemDeviceId);
    if (health !== 'released') return 'not-released';
    const binding: DdkBinding | undefined = this.bindings.get(systemDeviceId);
    if (binding === undefined) return 'released-unbound';
    // `resourcesReleased` is reported only after the extension confirms release of every native claim.
    binding.claimTokens.clear();
    try {
      await deviceManager.unbindDevice(systemDeviceId);
    } catch (error) {
      console.warn(`DDK resources were released, but DeviceManager unbind failed: ${this.fromPlatformError(
        'unbind released DDK driver', error as Object).message}`);
      return 'released-still-bound';
    }
    this.bindings.delete(systemDeviceId);
    try { binding.driver.remote.unregisterDeathRecipient(binding.deathRecipient, 0); } catch (_error) { }
    return 'released-unbound';
  }

  async bind(systemDeviceId: number): Promise<void> {
    if (this.bindings.has(systemDeviceId)) {
      const health: DdkDriverHealth = await this.checkHealth(systemDeviceId);
      if (health === 'healthy') return;
      if (health === 'released') await this.cleanupReleasedBinding(systemDeviceId);
      throw new DdkDriverClientError('Existing DDK binding is not healthy; retry after cleanup', -16, -16);
    }
    const systemDevice: DdkSystemDeviceInfo | undefined = this.listSystemDevices().find(
      (device: DdkSystemDeviceInfo): boolean => device.deviceId === systemDeviceId);
    if (systemDevice === undefined) {
      throw new DdkDriverClientError('USB device is no longer present in DeviceManager', 26300003, -19);
    }

    const deathRecipient: rpc.DeathRecipient = {
      onRemoteDied: (): void => { this.dropBinding(systemDeviceId); }
    };
    const onDisconnect = (_error: BusinessError | null, disconnectedId: number): void => {
      if (disconnectedId === systemDeviceId) this.dropBinding(systemDeviceId);
    };
    try {
      // Intentionally use the API 11 compatibility binder: the API 19 replacement requires
      // ACCESS_DDK_DRIVERS, which is outside this app's approved ACL profile.
      const driver: deviceManager.RemoteDeviceDriver = await deviceManager.bindDeviceDriver(systemDeviceId, onDisconnect);
      const binding: DdkBinding = {
        systemDevice,
        driver,
        deathRecipient,
        claimTokens: new Set<string>()
      };
      this.bindings.set(systemDeviceId, binding);
      driver.remote.registerDeathRecipient(deathRecipient, 0);
      const health: DdkRpcReply = await this.call(systemDeviceId, makeRequest('health'));
      if (classifyDdkDriverHealth(health.status, health.initialized, health.resourcesReleased) !== 'healthy') {
        await this.unbind(systemDeviceId);
        throw new DdkDriverClientError('DDK driver service is not initialized', health.status, mapDdkUsbErrno(health.status));
      }
    } catch (error) {
      throw this.fromPlatformError('bind DDK driver', error as Object);
    }
  }

  async unbind(systemDeviceId: number): Promise<void> {
    const binding: DdkBinding | undefined = this.bindings.get(systemDeviceId);
    if (binding === undefined) return;
    const tokens: Array<string> = Array.from(binding.claimTokens);
    for (let index: number = 0; index < tokens.length; index++) {
      const request: DdkRpcRequest = makeRequest('releaseInterface');
      request.handle = tokens[index];
      await this.call(systemDeviceId, request);
      binding.claimTokens.delete(tokens[index]);
    }
    try {
      // Pair with bindDeviceDriver; both compatibility APIs use ACCESS_EXTENSIONAL_DEVICE_DRIVER.
      await deviceManager.unbindDevice(systemDeviceId);
    } catch (error) {
      throw this.fromPlatformError('unbind DDK driver', error as Object);
    }
    binding.claimTokens.clear();
    this.bindings.delete(systemDeviceId);
    try { binding.driver.remote.unregisterDeathRecipient(binding.deathRecipient, 0); } catch (_error) { }
  }

  async unbindAll(): Promise<void> {
    const ids: Array<number> = Array.from(this.bindings.keys());
    for (let index: number = 0; index < ids.length; index++) {
      await this.unbind(ids[index]);
    }
  }

  async getDriverDeviceIds(systemDeviceId: number): Promise<Array<string>> {
    const response: DdkRpcReply = await this.call(systemDeviceId, makeRequest('getDevices'));
    if (!Array.isArray(response.value)) return [];
    const ids: Array<string> = [];
    (response.value as Array<Object>).forEach((value: Object): void => {
      if (typeof value === 'string') ids.push(value as string);
    });
    return ids;
  }

  async getDeviceDescriptor(systemDeviceId: number, ddkDeviceId: string): Promise<DdkDeviceDescriptor> {
    const request: DdkRpcRequest = makeRequest('getDeviceDescriptor');
    request.deviceId = ddkDeviceId;
    const response: DdkRpcReply = await this.call(systemDeviceId, request);
    if (response.value === undefined) throw new DdkDriverClientError('DDK returned no device descriptor', -5, -5);
    return response.value as DdkDeviceDescriptor;
  }

  async getActiveConfiguration(systemDeviceId: number, ddkDeviceId: string): Promise<number> {
    const request: DdkRpcRequest = makeRequest('getActiveConfiguration');
    request.deviceId = ddkDeviceId;
    const response: DdkRpcReply = await this.call(systemDeviceId, request);
    if (response.value === undefined) throw new DdkDriverClientError('DDK did not report the active configuration', -5, -5);
    const active: DdkActiveConfiguration = response.value as DdkActiveConfiguration;
    if (!Number.isInteger(active.configurationValue) || active.configurationValue < 1 || active.configurationValue > 255) {
      throw new DdkDriverClientError('DDK returned an invalid active configuration value', -22, -22);
    }
    return active.configurationValue;
  }

  async getConfigurationDescriptor(systemDeviceId: number, ddkDeviceId: string,
    descriptorIndex: number): Promise<DdkConfigurationDescriptor> {
    const request: DdkRpcRequest = makeRequest('getConfigDescriptor');
    request.deviceId = ddkDeviceId;
    request.configurationIndex = descriptorIndex;
    const response: DdkRpcReply = await this.call(systemDeviceId, request);
    if (response.value === undefined) throw new DdkDriverClientError('DDK returned no configuration descriptor', -5, -5);
    return response.value as DdkConfigurationDescriptor;
  }

  async claimInterface(systemDeviceId: number, ddkDeviceId: string, interfaceNumber: number): Promise<string> {
    const request: DdkRpcRequest = makeRequest('claimInterface');
    request.deviceId = ddkDeviceId;
    request.interfaceNumber = interfaceNumber;
    const response: DdkRpcReply = await this.call(systemDeviceId, request);
    if (typeof response.value !== 'string') throw new DdkDriverClientError('DDK returned no interface handle', -5, -5);
    const binding: DdkBinding = this.requireBinding(systemDeviceId);
    binding.claimTokens.add(response.value as string);
    return response.value as string;
  }

  async releaseInterface(systemDeviceId: number, handle: string): Promise<void> {
    const request: DdkRpcRequest = makeRequest('releaseInterface');
    request.handle = handle;
    await this.call(systemDeviceId, request);
    this.requireBinding(systemDeviceId).claimTokens.delete(handle);
  }

  async selectInterfaceSetting(systemDeviceId: number, handle: string, alternateSetting: number): Promise<void> {
    const request: DdkRpcRequest = makeRequest('selectInterfaceSetting');
    request.handle = handle;
    request.alternateSetting = alternateSetting;
    await this.call(systemDeviceId, request);
  }

  async controlTransfer(systemDeviceId: number, ddkDeviceId: string, setup: Array<number>,
    data: Array<number>, timeoutMs: number, interfaceHandle?: string): Promise<DdkTransferResult> {
    const request: DdkRpcRequest = makeRequest(interfaceHandle === undefined ? 'controlTransfer' : 'claimedControlTransfer');
    const expectation: DdkTransferExpectation = validateDdkTransferRequest(request.operation, 0, setup, data);
    request.deviceId = ddkDeviceId;
    request.handle = interfaceHandle ?? '';
    request.setup = setup.slice();
    request.data = data.slice(0, expectation.maxLength);
    request.timeoutMs = normalizeDdkTimeout(timeoutMs);
    return await this.transferCall(systemDeviceId, request);
  }

  async pipeTransfer(systemDeviceId: number, handle: string, endpointAddress: number,
    data: Array<number>, timeoutMs: number): Promise<DdkTransferResult> {
    validateDdkTransferRequest('pipeTransfer', endpointAddress, [], data);
    const request: DdkRpcRequest = makeRequest('pipeTransfer');
    request.handle = handle;
    request.endpointAddress = endpointAddress;
    request.data = data.slice();
    request.timeoutMs = normalizeDdkTimeout(timeoutMs);
    return await this.transferCall(systemDeviceId, request);
  }

  private async transferCall(systemDeviceId: number, request: DdkRpcRequest): Promise<DdkTransferResult> {
    const response: DdkRpcReply = await this.call(systemDeviceId, request);
    const actualLength: number = response.actualLength ?? 0;
    const data: Array<number> = response.data ?? [];
    const expectation: DdkTransferExpectation = getDdkTransferExpectation(request.operation,
      request.endpointAddress, request.setup, request.data);
    if (!isValidDdkTransferResult(expectation, actualLength, data)) {
      throw new DdkDriverClientError('DDK RPC transfer response has invalid length', -5, -5);
    }
    return { status: response.status, actualLength, data: data.slice() };
  }

  private async call(systemDeviceId: number, request: DdkRpcRequest): Promise<DdkRpcReply> {
    const binding: DdkBinding = this.requireBinding(systemDeviceId);
    const serialized: string = JSON.stringify(request);
    if (serialized.length > MAX_RPC_JSON_CHARS) {
      throw new DdkDriverClientError('DDK RPC request exceeds message size limit', -90, -90);
    }
    const data: rpc.MessageSequence = rpc.MessageSequence.create();
    const reply: rpc.MessageSequence = rpc.MessageSequence.create();
    try {
      data.writeString(serialized);
      const result: rpc.RequestResult = await binding.driver.remote.sendMessageRequest(
        DDK_RPC_CODE, data, reply, new rpc.MessageOption(rpc.MessageOption.TF_SYNC, RPC_WAIT_SECONDS));
      if (result.errCode !== 0) {
        throw new DdkDriverClientError(`DDK RPC transport failed (${result.errCode})`, result.errCode, -5);
      }
      const responseText: string = result.reply.readString();
      if (responseText.length > MAX_RPC_JSON_CHARS) {
        throw new DdkDriverClientError('DDK RPC response exceeds message size limit', -90, -90);
      }
      const response: DdkRpcReply = JSON.parse(responseText) as DdkRpcReply;
      if (!Number.isInteger(response.status)) {
        throw new DdkDriverClientError('DDK RPC returned a malformed status', -5, -5);
      }
      if (response.status !== 0 && request.operation !== 'health') {
        const message: string = response.error ?? `DDK operation failed (${response.status})`;
        throw new DdkDriverClientError(message, response.status, mapDdkUsbErrno(response.status));
      }
      return response;
    } catch (error) {
      throw this.fromPlatformError(`DDK ${request.operation}`, error as Object);
    } finally {
      try { data.reclaim(); } catch (_error) { }
      try { reply.reclaim(); } catch (_error) { }
    }
  }

  private requireBinding(systemDeviceId: number): DdkBinding {
    const binding: DdkBinding | undefined = this.bindings.get(systemDeviceId);
    if (binding === undefined) {
      throw new DdkDriverClientError('DDK driver is not bound to this USB device', 26300003, -19);
    }
    return binding;
  }

  private dropBinding(systemDeviceId: number): void {
    const binding: DdkBinding | undefined = this.bindings.get(systemDeviceId);
    if (binding === undefined) return;
    this.bindings.delete(systemDeviceId);
    try { binding.driver.remote.unregisterDeathRecipient(binding.deathRecipient, 0); } catch (_error) { }
    binding.claimTokens.clear();
    this.disconnectListeners.forEach((listener: (deviceId: number) => void): void => listener(systemDeviceId));
  }

  private fromPlatformError(operation: string, error: Object): DdkDriverClientError {
    if (error instanceof DdkDriverClientError) return error;
    const businessError: BusinessError = error as BusinessError;
    const status: number = businessError.code ?? -5;
    const detail: string = businessError.message ?? String(error);
    return new DdkDriverClientError(`${operation}: ${detail}`, status, mapDdkUsbErrno(status));
  }
}
