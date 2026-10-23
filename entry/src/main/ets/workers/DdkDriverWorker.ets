import { MessageEvents, worker } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import usbarcDdk from 'libusbarc_ddk.so';
import { normalizeNativeDdkReply } from '../services/DdkDriverRpcContract';
import { DdkRpcReply, DdkRpcRequest } from '../services/DdkWorkerContract';

const MAX_PIPE_BYTES: number = 1048576;
const MAX_CONTROL_BYTES: number = 1024;
const DOMAIN: number = 0xDDB;
const TAG: string = 'DdkOwner';
const port = worker.workerPort;
let ownsInitialization: boolean = false;

interface DdkClaimIdentity {
  deviceId: string;
  interfaceNumber: number;
}

const activeClaims: Map<string, DdkClaimIdentity> = new Map<string, DdkClaimIdentity>();

function errorReply(requestId: number, status: number, error: string): DdkRpcReply {
  return { requestId, status, error };
}

function logLifecycle(request: DdkRpcRequest, reply: DdkRpcReply): void {
  if (request.operation !== 'init' && request.operation !== 'release' &&
    request.operation !== 'getDeviceDescriptor' && request.operation !== 'claimInterface' &&
    request.operation !== 'releaseInterface') return;
  let deviceId: string = request.deviceId;
  let interfaceNumber: number = request.interfaceNumber;
  if (request.operation === 'releaseInterface') {
    const claim: DdkClaimIdentity | undefined = activeClaims.get(request.handle);
    if (claim !== undefined) {
      deviceId = claim.deviceId;
      interfaceNumber = claim.interfaceNumber;
    }
  }
  const numericId: number = Number(deviceId);
  const busNum: number = Number.isSafeInteger(numericId) && numericId >= 0 ?
    Math.floor(numericId / 4294967296) : -1;
  const devAddress: number = Number.isSafeInteger(numericId) && numericId >= 0 ?
    numericId - busNum * 4294967296 : -1;
  hilog.info(DOMAIN, TAG,
    'DDK %{public}s request=%{public}d device=%{public}s bus=%{public}d address=%{public}d interface=%{public}d status=%{public}d',
    request.operation, request.requestId, deviceId, busNum, devAddress, interfaceNumber, reply.status);
}

function dispatch(request: DdkRpcRequest): DdkRpcReply {
  const requestId: number = request.requestId;
  if (!Number.isInteger(requestId) || request.operation.length === 0 || request.operation.length > 64 ||
    request.data.length > MAX_PIPE_BYTES || request.setup.length > 8 ||
    request.deviceId.length > 20 || request.handle.length > 64 ||
    !Number.isInteger(request.interfaceNumber) || request.interfaceNumber < 0 || request.interfaceNumber > 255 ||
    !Number.isInteger(request.alternateSetting) || request.alternateSetting < 0 || request.alternateSetting > 255 ||
    !Number.isInteger(request.configurationIndex) || request.configurationIndex < 0 ||
    request.configurationIndex > 255 || !Number.isInteger(request.endpointAddress) ||
    request.endpointAddress < 0 || request.endpointAddress > 255 || !Number.isInteger(request.timeoutMs) ||
    request.timeoutMs < 0 || request.timeoutMs > 30000) {
    return errorReply(requestId, -22, 'Invalid DDK worker request bounds');
  }
  for (let index: number = 0; index < request.data.length; index++) {
    if (!Number.isInteger(request.data[index]) || request.data[index] < 0 || request.data[index] > 255) {
      return errorReply(requestId, -22, 'DDK worker data contains an invalid byte');
    }
  }
  for (let index: number = 0; index < request.setup.length; index++) {
    if (!Number.isInteger(request.setup[index]) || request.setup[index] < 0 || request.setup[index] > 255) {
      return errorReply(requestId, -22, 'DDK worker setup contains an invalid byte');
    }
  }
  if (request.operation === 'init') {
    if (usbarcDdk.isInitialized()) {
      return { requestId, status: ownsInitialization ? 0 : -16, initialized: true,
        error: ownsInitialization ? undefined : 'Native DDK state is owned by another worker' };
    }
    const status: number = usbarcDdk.init();
    ownsInitialization = status === 0;
    return { requestId, status, initialized: ownsInitialization };
  }
  if (request.operation === 'health') {
    const initialized: boolean = usbarcDdk.isInitialized();
    return { requestId, status: initialized ? 0 : 27400002, initialized,
      resourcesReleased: !initialized };
  }
  if (request.operation === 'release') {
    if (!ownsInitialization) return errorReply(requestId, -16, 'This worker does not own DDK initialization');
    const status: number = usbarcDdk.release();
    if (status === 0) ownsInitialization = false;
    return { requestId, status, initialized: usbarcDdk.isInitialized(), resourcesReleased: status === 0 };
  }
  if (!ownsInitialization || !usbarcDdk.isInitialized()) {
    return errorReply(requestId, 27400002, 'DDK worker has not initialized the native backend');
  }
  if ((request.operation === 'controlTransfer' || request.operation === 'claimedControlTransfer') &&
    request.setup.length !== 8) return errorReply(requestId, -22, 'Control transfer setup must contain 8 bytes');
  if ((request.operation === 'controlTransfer' || request.operation === 'claimedControlTransfer') &&
    request.setup.length === 8) {
    const length: number = request.setup[6] | (request.setup[7] << 8);
    if (length > MAX_CONTROL_BYTES || request.data.length < length) {
      return errorReply(requestId, -22, 'Control transfer exceeds worker bounds');
    }
  }
  let raw: Object | number;
  switch (request.operation) {
    case 'getDeviceDescriptor': raw = usbarcDdk.getDeviceDescriptor(request.deviceId) as Object; break;
    case 'getActiveConfiguration': raw = usbarcDdk.getActiveConfiguration(request.deviceId) as Object; break;
    case 'getConfigDescriptor': raw = usbarcDdk.getConfigDescriptor(request.deviceId,
      request.configurationIndex) as Object; break;
    case 'claimInterface': raw = usbarcDdk.claimInterface(request.deviceId,
      request.interfaceNumber) as Object; break;
    case 'releaseInterface': raw = usbarcDdk.releaseInterface(request.handle) as Object; break;
    case 'selectInterfaceSetting': raw = usbarcDdk.selectInterfaceSetting(request.handle,
      request.alternateSetting) as Object; break;
    case 'controlTransfer': raw = usbarcDdk.controlTransfer(request.deviceId, request.setup,
      request.data, request.timeoutMs) as Object; break;
    case 'claimedControlTransfer': raw = usbarcDdk.claimedControlTransfer(request.handle,
      request.setup, request.data, request.timeoutMs) as Object; break;
    case 'pipeTransfer': raw = usbarcDdk.pipeTransfer(request.handle, request.endpointAddress,
      request.data, request.timeoutMs) as Object; break;
    default: return errorReply(requestId, -22, 'Unsupported DDK worker operation');
  }
  const normalized = normalizeNativeDdkReply(raw as Object);
  return { requestId, status: normalized.status, error: normalized.error,
    value: normalized.value, actualLength: normalized.actualLength, data: normalized.data };
}

port.onmessage = (event: MessageEvents): void => {
  let requestId: number = -1;
  try {
    const request: DdkRpcRequest = event.data as DdkRpcRequest;
    requestId = request.requestId;
    const reply: DdkRpcReply = dispatch(request);
    if (request.operation === 'claimInterface' && reply.status === 0 && typeof reply.value === 'string') {
      const identity: DdkClaimIdentity = { deviceId: request.deviceId, interfaceNumber: request.interfaceNumber };
      activeClaims.set(reply.value as string, identity);
    }
    if (request.operation === 'releaseInterface' && reply.status === 0) activeClaims.delete(request.handle);
    logLifecycle(request, reply);
    port.postMessage(reply as Object);
  } catch (error) {
    const detail: string = error instanceof Error ? error.message : 'Native DDK operation failed';
    port.postMessage(errorReply(requestId, -5, detail) as Object);
  }
};
