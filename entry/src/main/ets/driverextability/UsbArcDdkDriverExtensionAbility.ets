import { DriverExtensionAbility } from '@kit.DriverDevelopmentKit';
import { Want } from '@kit.AbilityKit';
import { rpc } from '@kit.IPCKit';
import usbarcDdk from 'libusbarc_ddk.so';
import {
  cleanupDdkAshmem,
  DdkDriverWireReply,
  DdkDriverWireRequest,
  normalizeNativeDdkReply,
  parseDdkDriverWireRequest,
  validateDdkSharedTransfer,
  validateDdkSharedTransferResult
} from '../services/DdkDriverRpcContract';

const DDK_RPC_CODE: number = 0x5542;
const MAX_RPC_JSON_CHARS: number = 38000;
const MAX_RPC_INLINE_TRANSFER_BYTES: number = 8000;

class DriverRemoteStub extends rpc.RemoteObject {
  private initialized: boolean;
  private resourcesReleased: boolean;

  constructor(descriptor: string, initialized: boolean, resourcesReleased: boolean) {
    super(descriptor);
    this.initialized = initialized;
    this.resourcesReleased = resourcesReleased;
  }

  setHealth(initialized: boolean, resourcesReleased: boolean): void {
    this.initialized = initialized;
    this.resourcesReleased = resourcesReleased;
  }

  onRemoteMessageRequest(code: number, data: rpc.MessageSequence, reply: rpc.MessageSequence,
    option: rpc.MessageOption): boolean {
    void option;
    if (code !== DDK_RPC_CODE) return false;
    let response: DdkDriverWireReply = { status: -5, error: 'DDK RPC request did not complete' };
    let ashmem: rpc.Ashmem | undefined = undefined;
    let ashmemMapped: boolean = false;
    let request: DdkDriverWireRequest | undefined = undefined;
    try {
      const raw: string = data.readString();
      if (raw.length > MAX_RPC_JSON_CHARS) {
        response = { status: -90, error: 'DDK RPC request exceeds message size limit' };
      } else {
        request = parseDdkDriverWireRequest(raw);
        if (request.sharedMemoryTransfer) {
          const receivedAshmem: rpc.Ashmem = data.readAshmem();
          ashmem = receivedAshmem;
          validateDdkSharedTransfer(request.operation, request.sharedMemoryTransfer, request.sharedMemoryLength,
            receivedAshmem.getAshmemSize(), request.data.length);
          receivedAshmem.mapReadWriteAshmem();
          ashmemMapped = true;
          const isInput: boolean = (request.endpointAddress & 0x80) !== 0;
          request.data = isInput ? createZeroBytes(request.sharedMemoryLength) : request.sharedMemoryLength === 0 ? [] :
            arrayBufferToBytes(receivedAshmem.readDataFromAshmem(request.sharedMemoryLength, 0));
          response = this.dispatch(request);
          if (response.status === 0) {
            const responseData: Array<number> = response.data ?? [];
            if (!validateDdkSharedTransferResult(isInput, request.sharedMemoryLength,
              response.actualLength ?? 0, responseData)) {
              response = { status: -5, error: 'DDK returned invalid shared-transfer length or data' };
            } else {
              if (isInput && responseData.length > 0) {
                receivedAshmem.writeDataToAshmem(bytesToArrayBuffer(responseData), responseData.length, 0);
              }
              response.data = [];
            }
          }
        } else if (request.operation === 'pipeTransfer' || request.sharedMemoryLength !== 0) {
          response = { status: -95, error: 'DDK pipe transfer requires rpc.Ashmem shared memory' };
        } else if (request.data.length > MAX_RPC_INLINE_TRANSFER_BYTES) {
          response = { status: -90, error: `DDK control payload exceeds ${MAX_RPC_INLINE_TRANSFER_BYTES}-byte JSON limit` };
        } else {
          response = this.dispatch(request);
        }
      }
    } catch (error) {
      const message: string = error instanceof Error ? error.message : 'Malformed DDK RPC request';
      const isSharedPipe: boolean = request?.operation === 'pipeTransfer';
      response = { status: isSharedPipe ? -95 : -22, error: isSharedPipe ? `DDK Ashmem transport failed: ${message}` : message };
    } finally {
      if (ashmem !== undefined) {
        try {
          const cleanupAshmem: rpc.Ashmem = ashmem;
          cleanupDdkAshmem((): void => cleanupAshmem.unmapAshmem(),
            (): void => cleanupAshmem.closeAshmem(), ashmemMapped);
        } catch (error) {
          const message: string = error instanceof Error ? error.message : 'unknown error';
          console.error(`DDK Ashmem cleanup failed: ${message}`);
          if (response.status === 0) {
            response = { status: -5, error: `DDK Ashmem cleanup failed: ${message}` };
          }
        }
      }
    }
    let serialized: string = JSON.stringify(response);
    if (serialized.length > MAX_RPC_JSON_CHARS) {
      serialized = JSON.stringify({ status: -90, error: 'DDK RPC response exceeds message size limit' } as DdkDriverWireReply);
    }
    reply.writeString(serialized);
    return true;
  }

  private dispatch(request: DdkDriverWireRequest): DdkDriverWireReply {
    if (request.operation === 'health') {
      const initialized: boolean = this.initialized && usbarcDdk.isInitialized();
      return { status: initialized ? 0 : 27400002, initialized, resourcesReleased: this.resourcesReleased };
    }
    if (!this.initialized || !usbarcDdk.isInitialized()) {
      return { status: 27400002, error: 'DDK extension is not initialized' };
    }
    switch (request.operation) {
      case 'getDevices':
        return normalizeNativeDdkReply(usbarcDdk.getDevices() as Object);
      case 'getDeviceDescriptor':
        return normalizeNativeDdkReply(usbarcDdk.getDeviceDescriptor(request.deviceId) as Object);
      case 'getActiveConfiguration':
        return normalizeNativeDdkReply(usbarcDdk.getActiveConfiguration(request.deviceId) as Object);
      case 'getConfigDescriptor':
        return normalizeNativeDdkReply(
          usbarcDdk.getConfigDescriptor(request.deviceId, request.configurationIndex) as Object);
      case 'claimInterface':
        return normalizeNativeDdkReply(
          usbarcDdk.claimInterface(request.deviceId, request.interfaceNumber) as Object);
      case 'releaseInterface':
        return normalizeNativeDdkReply(usbarcDdk.releaseInterface(request.handle) as Object);
      case 'selectInterfaceSetting':
        return normalizeNativeDdkReply(
          usbarcDdk.selectInterfaceSetting(request.handle, request.alternateSetting) as Object);
      case 'controlTransfer':
        return normalizeNativeDdkReply(usbarcDdk.controlTransfer(request.deviceId, request.setup,
          request.data, request.timeoutMs) as Object);
      case 'claimedControlTransfer':
        return normalizeNativeDdkReply(usbarcDdk.claimedControlTransfer(request.handle, request.setup,
          request.data, request.timeoutMs) as Object);
      case 'pipeTransfer':
        return normalizeNativeDdkReply(usbarcDdk.pipeTransfer(request.handle, request.endpointAddress,
          request.data, request.timeoutMs) as Object);
      default:
        return { status: -22, error: 'Unsupported DDK RPC operation' };
    }
  }
}

function createZeroBytes(length: number): Array<number> {
  const result: Array<number> = [];
  for (let index: number = 0; index < length; index++) result.push(0);
  return result;
}

function arrayBufferToBytes(buffer: ArrayBuffer): Array<number> {
  const view: Uint8Array = new Uint8Array(buffer);
  const result: Array<number> = [];
  for (let index: number = 0; index < view.length; index++) result.push(view[index]);
  return result;
}

function bytesToArrayBuffer(bytes: Array<number>): ArrayBuffer {
  const result: Uint8Array = new Uint8Array(bytes.length);
  for (let index: number = 0; index < bytes.length; index++) result[index] = bytes[index];
  return result.buffer;
}

export default class UsbArcDdkDriverExtensionAbility extends DriverExtensionAbility {
  private initialized: boolean = false;
  private resourcesReleased: boolean = true;
  private remote: DriverRemoteStub | undefined = undefined;

  onInit(want: Want): void {
    void want;
    const status: number = usbarcDdk.init();
    this.initialized = status === 0 && usbarcDdk.isInitialized();
    this.resourcesReleased = !this.initialized;
    console.info(`USBArc DDK extension initialized=${this.initialized}, status=${status}`);
    this.remote?.setHealth(this.initialized, this.resourcesReleased);
  }

  onRelease(): void {
    let status: number = 0;
    if (this.initialized) {
      status = usbarcDdk.release();
      console.info(`USBArc DDK extension release status=${status}`);
    }
    this.initialized = false;
    this.resourcesReleased = status === 0 && !usbarcDdk.isInitialized();
    this.remote?.setHealth(false, this.resourcesReleased);
  }

  onConnect(want: Want): rpc.RemoteObject {
    void want;
    if (this.remote === undefined) {
      this.remote = new DriverRemoteStub('io.github.rockymtnwolf.usbarc.UsbArcDdkDriver',
        this.initialized, this.resourcesReleased);
    }
    return this.remote;
  }

  onDisconnect(want: Want): void {
    void want;
  }
}
