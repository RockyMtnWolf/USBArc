import { usbManager } from '@kit.BasicServicesKit';
import { ErrorEvent, MessageEvents, worker } from '@kit.ArkTS';
import {
  shouldHideDdkHubRow,
  shouldHideDdkSystemDescription,
  UsbHubDeviceDescriptor,
  usbManagerHubDescriptor
} from '../usb/UsbHubClassification';
import { UsbPhysicalAddress } from '../usb/UsbDeviceMetadata';
import { MAX_DDK_SHARED_TRANSFER_BYTES } from './DdkDriverRpcContract';
import { DdkRpcReply, DdkRpcRequest } from './DdkWorkerContract';
export { DdkRpcReply, DdkRpcRequest } from './DdkWorkerContract';

export const MAX_DDK_RPC_TRANSFER_BYTES: number = MAX_DDK_SHARED_TRANSFER_BYTES;
export const MAX_DDK_CONTROL_TRANSFER_BYTES: number = 1024;

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

export interface DdkWorkerRequestTransport {
  request(request: DdkRpcRequest): Promise<DdkRpcReply>;
}

interface DdkPendingReply {
  resolve: (reply: DdkRpcReply) => void;
  reject: (error: Object) => void;
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
  if (status === 22900001 || status === 26300001) return -5;
  if (status === 27400004) return -110;
  if (status === 27400001) return -12;
  if (status === 27400003) return -5;
  return -5;
}

export function formatDdkPlatformErrorMessage(operation: string, status: number, detail: string): string {
  return `${operation} failed (platform code ${status}): ${detail}`;
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

export function makeDdkPhysicalDeviceId(busNum: number, devAddress: number): number | undefined {
  if (!Number.isInteger(busNum) || busNum < 0 || busNum > 0x1fffff ||
    !Number.isInteger(devAddress) || devAddress < 1 || devAddress > 127) return undefined;
  const id: number = busNum * 4294967296 + devAddress;
  return Number.isSafeInteger(id) ? id : undefined;
}

/** Decimal spelling retained for diagnostics/tests that previously built the uint64 ID. */
export function makeDdkProbeDeviceId(busNum: number, devAddress: number): string | undefined {
  const deviceId: number | undefined = makeDdkPhysicalDeviceId(busNum, devAddress);
  return deviceId === undefined ? undefined : deviceId.toString(10);
}

export function getDdkPhysicalBusAddress(deviceId: number): UsbPhysicalAddress | undefined {
  if (!Number.isSafeInteger(deviceId) || deviceId < 0) return undefined;
  const busNum: number = Math.floor(deviceId / 4294967296);
  const devAddress: number = deviceId - busNum * 4294967296;
  if (busNum > 0x1fffff || devAddress < 1 || devAddress > 127) return undefined;
  return { busNum, devAddress };
}

function toSystemDeviceInfo(device: Readonly<usbManager.USBDevice>): DdkSystemDeviceInfo | undefined {
  const deviceId: number | undefined = makeDdkPhysicalDeviceId(device.busNum, device.devAddress);
  if (deviceId === undefined) return undefined;
  return {
    deviceId,
    vendorId: device.vendorId,
    productId: device.productId,
    description: device.name
  };
}

function makeRequest(operation: string): DdkRpcRequest {
  return {
    requestId: 0,
    operation,
    deviceId: '',
    interfaceNumber: 0,
    handle: '',
    alternateSetting: 0,
    configurationIndex: 0,
    endpointAddress: 0,
    timeoutMs: 0,
    setup: [],
    data: [],
    sharedMemoryTransfer: false,
    sharedMemoryLength: 0
  };
}

/** One persistent worker owns NDK init/release and serializes all USB I/O. */
class DdkWorkerTransport implements DdkWorkerRequestTransport {
  private thread: worker.ThreadWorker | undefined = undefined;
  private pending: Map<number, DdkPendingReply> = new Map<number, DdkPendingReply>();
  private failed: boolean = false;

  async request(request: DdkRpcRequest): Promise<DdkRpcReply> {
    if (this.failed) throw new DdkDriverClientError('DDK worker stopped; native claims are retained', -16, -16);
    this.ensureThread();
    return await new Promise<DdkRpcReply>((resolve: (reply: DdkRpcReply) => void,
      reject: (error: Object) => void): void => {
      const pendingReply: DdkPendingReply = { resolve, reject };
      this.pending.set(request.requestId, pendingReply);
      try {
        this.thread?.postMessage(request as Object);
      } catch (error) {
        this.pending.delete(request.requestId);
        reject(error as Object);
      }
    });
  }

  private ensureThread(): void {
    if (this.thread !== undefined) return;
    try {
      const instance: worker.ThreadWorker = new worker.ThreadWorker('entry/ets/workers/DdkDriverWorker.ets', {
        name: 'USBArc-DDK-owner'
      });
      instance.onmessage = (event: MessageEvents): void => {
        const reply: DdkRpcReply = event.data as DdkRpcReply;
        const pending: DdkPendingReply | undefined = this.pending.get(reply.requestId);
        if (pending === undefined) return;
        this.pending.delete(reply.requestId);
        pending.resolve(reply);
      };
      instance.onerror = (_event: ErrorEvent): void => { this.fail(); };
      instance.onexit = (_code: number): void => { this.fail(); };
      this.thread = instance;
    } catch (error) {
      this.failed = true;
      throw new DdkDriverClientError(`Unable to start DDK worker: ${String(error)}`, -5, -5);
    }
  }

  private fail(): void {
    this.failed = true;
    this.pending.forEach((pending: DdkPendingReply): void => {
      pending.reject(new DdkDriverClientError('DDK worker exited; native claims are retained', -16, -16));
    });
    this.pending.clear();
  }
}

export class DdkDriverClient {
  private bindings: Map<number, DdkBinding> = new Map<number, DdkBinding>();
  private disconnectListeners: Set<(systemDeviceId: number) => void> = new Set<(systemDeviceId: number) => void>();
  private workerTransport: DdkWorkerRequestTransport;
  private readonly systemDeviceProvider: (() => Array<DdkSystemDeviceInfo>) | undefined;
  private nextRequestId: number = 1;
  private initialized: boolean = false;
  private transportFailed: boolean = false;

  constructor(workerTransport?: DdkWorkerRequestTransport,
    systemDeviceProvider?: () => Array<DdkSystemDeviceInfo>) {
    this.workerTransport = workerTransport ?? new DdkWorkerTransport();
    this.systemDeviceProvider = systemDeviceProvider;
  }

  listSystemDevices(): Array<DdkSystemDeviceInfo> {
    if (this.systemDeviceProvider !== undefined) return this.systemDeviceProvider();
    try {
      const result: Array<DdkSystemDeviceInfo> = [];
      const managerDevices: Array<Readonly<usbManager.USBDevice>> = usbManager.getDevices();
      const managerDescriptors: Array<UsbHubDeviceDescriptor> = managerDevices.map(
        (item: Readonly<usbManager.USBDevice>): UsbHubDeviceDescriptor => usbManagerHubDescriptor(item));
      managerDevices.forEach((device: Readonly<usbManager.USBDevice>): void => {
        const mapped: DdkSystemDeviceInfo | undefined = toSystemDeviceInfo(device);
        if (mapped === undefined) return;
        if (shouldHideDdkHubRow(mapped.vendorId, mapped.productId, managerDescriptors) ||
          shouldHideDdkSystemDescription(mapped.description, mapped.vendorId, mapped.productId)) return;
        result.push(mapped);
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
    if (this.transportFailed) return 'unavailable';
    if (!this.initialized) return 'released';
    try {
      const response: DdkRpcReply = await this.workerTransport.request(this.makeWorkerRequest('health'));
      return response.status === 0 && response.initialized === true ? 'healthy' : 'unavailable';
    } catch (_error) {
      this.transportFailed = true;
      return 'unavailable';
    }
  }

  async cleanupReleasedBinding(systemDeviceId: number): Promise<DdkReleasedCleanup> {
    const binding: DdkBinding | undefined = this.bindings.get(systemDeviceId);
    if (binding !== undefined && binding.claimTokens.size > 0) return 'not-released';
    if (binding !== undefined) this.bindings.delete(systemDeviceId);
    return 'released-unbound';
  }

  async bind(systemDeviceId: number): Promise<void> {
    const systemDevice: DdkSystemDeviceInfo | undefined = this.listSystemDevices().find(
      (device: DdkSystemDeviceInfo): boolean => device.deviceId === systemDeviceId);
    if (systemDevice === undefined) {
      throw new DdkDriverClientError('USB device is no longer present in USBManager', 26300003, -19);
    }

    try {
      await this.ensureInitialized();
      const response: DdkRpcReply = await this.workerTransport.request(this.makeWorkerRequest(
        'getDeviceDescriptor', systemDeviceId.toString()));
      if (response.status !== 0) throw this.makeError('read DDK descriptor', response.status,
        response.error ?? 'descriptor request failed');
      if (response.value === undefined) throw new DdkDriverClientError('DDK device descriptor is unavailable', response.status, mapDdkUsbErrno(response.status));
      const descriptor: DdkDeviceDescriptor = response.value as DdkDeviceDescriptor;
      if (descriptor.id !== systemDeviceId.toString() || descriptor.vendorId !== systemDevice.vendorId ||
        descriptor.productId !== systemDevice.productId) {
        throw new DdkDriverClientError('DDK device identity does not match the selected USB device', -19, -19);
      }
      if (!this.bindings.has(systemDeviceId)) this.bindings.set(systemDeviceId,
        { systemDevice, claimTokens: new Set<string>() });
    } catch (error) {
      throw this.fromError('initialize DDK worker', error);
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
    binding.claimTokens.clear();
    this.bindings.delete(systemDeviceId);
  }

  async unbindAll(): Promise<void> {
    const ids: Array<number> = Array.from(this.bindings.keys());
    for (let index: number = 0; index < ids.length; index++) {
      await this.unbind(ids[index]);
    }
    if (this.initialized) {
      const result: DdkRpcReply = await this.workerTransport.request(this.makeWorkerRequest('release'));
      if (result.status !== 0) throw this.makeError('release DDK', result.status, result.error ?? 'native release failed');
      this.initialized = false;
    }
  }

  async getDriverDeviceIds(systemDeviceId: number): Promise<Array<string>> {
    const binding: DdkBinding = this.requireBinding(systemDeviceId);
    const descriptor: DdkDeviceDescriptor = await this.getDeviceDescriptor(systemDeviceId,
      systemDeviceId.toString());
    if (descriptor.vendorId !== binding.systemDevice.vendorId ||
      descriptor.productId !== binding.systemDevice.productId || descriptor.id !== systemDeviceId.toString()) return [];
    return [descriptor.id];
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
    request.sharedMemoryTransfer = false;
    request.sharedMemoryLength = 0;
    request.timeoutMs = normalizeDdkTimeout(timeoutMs);
    request.data = data.slice();
    return await this.transferCall(systemDeviceId, request);
  }

  private async transferCall(systemDeviceId: number, request: DdkRpcRequest): Promise<DdkTransferResult> {
    const response: DdkRpcReply = await this.call(systemDeviceId, request);
    const actualLength: number = response.actualLength ?? 0;
    let data: Array<number> = response.data ?? [];
    const isInput: boolean = request.operation === 'pipeTransfer' ?
      (request.endpointAddress & 0x80) !== 0 : getDdkTransferExpectation(request.operation,
        request.endpointAddress, request.setup, request.data).isInput;
    const maxLength: number = getDdkTransferExpectation(request.operation,
      request.endpointAddress, request.setup, request.data).maxLength;
    const valid: boolean = isValidDdkTransferResult({ isInput, maxLength }, actualLength, data);
    if (!valid) {
      throw new DdkDriverClientError('DDK RPC transfer response has invalid length', -5, -5);
    }
    return { status: response.status, actualLength, data: data.slice() };
  }

  private async call(systemDeviceId: number, request: DdkRpcRequest): Promise<DdkRpcReply> {
    this.requireBinding(systemDeviceId);
    const response: DdkRpcReply = await this.workerTransport.request(this.makeWorkerRequest(request.operation,
      request.deviceId || systemDeviceId.toString(), request.interfaceNumber, request.handle,
      request.alternateSetting, request.configurationIndex, request.endpointAddress, request.timeoutMs,
      request.setup, request.data));
    if (!Number.isInteger(response.status)) throw new DdkDriverClientError('DDK worker returned malformed status', -5, -5);
    if (response.status !== 0 && request.operation !== 'health') {
      throw this.makeError(`DDK ${request.operation}`, response.status, response.error ?? 'native operation failed');
    }
    return response;
  }

  private requireBinding(systemDeviceId: number): DdkBinding {
    const binding: DdkBinding | undefined = this.bindings.get(systemDeviceId);
    if (binding === undefined) {
      throw new DdkDriverClientError('DDK driver is not bound to this USB device', 26300003, -19);
    }
    return binding;
  }

  private async ensureInitialized(): Promise<void> {
    if (this.transportFailed) throw new DdkDriverClientError('DDK worker is unavailable; claims are retained', -16, -16);
    if (this.initialized) return;
    const reply: DdkRpcReply = await this.workerTransport.request(this.makeWorkerRequest('init'));
    if (reply.status !== 0) throw this.makeError('initialize DDK', reply.status, reply.error ?? 'native init failed');
    this.initialized = true;
  }

  private makeWorkerRequest(operation: string, deviceId: string = '', interfaceNumber: number = 0,
    handle: string = '', alternateSetting: number = 0, configurationIndex: number = 0,
    endpointAddress: number = 0, timeoutMs: number = 0, setup: Array<number> = [], data: Array<number> = []): DdkRpcRequest {
    const requestId: number = this.nextRequestId++;
    return { requestId, operation, deviceId, interfaceNumber, handle, alternateSetting,
      configurationIndex, endpointAddress, timeoutMs, setup: setup.slice(), data: data.slice(),
      sharedMemoryTransfer: false, sharedMemoryLength: 0 };
  }

  private makeError(operation: string, status: number, detail: string): DdkDriverClientError {
    return new DdkDriverClientError(formatDdkPlatformErrorMessage(operation, status, detail), status,
      mapDdkUsbErrno(status));
  }

  private fromError(operation: string, error: Object): DdkDriverClientError {
    if (error instanceof DdkDriverClientError) return error;
    return new DdkDriverClientError(`${operation} failed: ${String(error)}`, -5, -5);
  }

  private fromPlatformError(operation: string, error: Object): DdkDriverClientError {
    if (error instanceof DdkDriverClientError) return error;
    return this.fromError(operation, error);
  }
}
