import { DriverExtensionAbility } from '@kit.DriverDevelopmentKit';
import { Want } from '@kit.AbilityKit';
import { rpc } from '@kit.IPCKit';
import usbarcDdk from 'libusbarc_ddk.so';

const DDK_RPC_CODE: number = 0x5542;
const MAX_RPC_JSON_CHARS: number = 38000;
const MAX_RPC_TRANSFER_BYTES: number = 8000;

interface DriverRequest {
  operation: string;
  deviceId: string;
  interfaceNumber: number;
  handle: string;
  alternateSetting: number;
  configurationValue: number;
  endpointAddress: number;
  timeoutMs: number;
  setup: Array<number>;
  data: Array<number>;
}

interface DdkStatusResponse {
  status: number;
  initialized?: boolean;
  error?: string;
}

function getStringField(source: Record<string, Object>, name: string): string {
  const value: Object | undefined = source[name];
  return typeof value === 'string' ? value as string : '';
}

function getNumberField(source: Record<string, Object>, name: string): number {
  const value: Object | undefined = source[name];
  return typeof value === 'number' ? value as number : 0;
}

function getArrayField(source: Record<string, Object>, name: string): Array<number> {
  const value: Object | undefined = source[name];
  if (!Array.isArray(value)) return [];
  const result: Array<number> = [];
  value.forEach((item: Object) => {
    if (typeof item === 'number' && item >= 0 && item <= 255) result.push(item as number);
  });
  return result;
}

function parseRequest(raw: string): DriverRequest {
  const source: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
  return {
    operation: getStringField(source, 'operation'),
    deviceId: getStringField(source, 'deviceId'),
    interfaceNumber: getNumberField(source, 'interfaceNumber'),
    handle: getStringField(source, 'handle'),
    alternateSetting: getNumberField(source, 'alternateSetting'),
    configurationValue: getNumberField(source, 'configurationValue'),
    endpointAddress: getNumberField(source, 'endpointAddress'),
    timeoutMs: getNumberField(source, 'timeoutMs'),
    setup: getArrayField(source, 'setup'),
    data: getArrayField(source, 'data')
  };
}

class DriverRemoteStub extends rpc.RemoteObject {
  constructor(descriptor: string) {
    super(descriptor);
  }

  onRemoteMessageRequest(code: number, data: rpc.MessageSequence, reply: rpc.MessageSequence,
    option: rpc.MessageOption): boolean {
    void option;
    if (code !== DDK_RPC_CODE) return false;
    const raw: string = data.readString();
    let response: string;
    try {
      if (raw.length > MAX_RPC_JSON_CHARS) {
        response = JSON.stringify({ status: -90, error: 'DDK RPC request exceeds message size limit' } as DdkStatusResponse);
      } else {
        const request: DriverRequest = parseRequest(raw);
        if (request.data.length > MAX_RPC_TRANSFER_BYTES) {
          response = JSON.stringify({ status: -90,
            error: `DDK RPC transfer exceeds ${MAX_RPC_TRANSFER_BYTES}-byte limit` } as DdkStatusResponse);
        } else {
          const serialized: string = JSON.stringify(this.dispatch(request));
          response = serialized.length > MAX_RPC_JSON_CHARS ?
            JSON.stringify({ status: -90, error: 'DDK RPC response exceeds message size limit' } as DdkStatusResponse) :
            serialized;
        }
      }
    } catch (error) {
      response = JSON.stringify({ status: -5, error: String(error) } as DdkStatusResponse);
    }
    reply.writeString(response);
    return true;
  }

  private dispatch(request: DriverRequest): Object {
    switch (request.operation) {
      case 'health':
        return { status: usbarcDdk.isInitialized() ? 0 : 27400002,
          initialized: usbarcDdk.isInitialized() } as DdkStatusResponse;
      case 'getDevices':
        return usbarcDdk.getDevices();
      case 'getDeviceDescriptor':
        return usbarcDdk.getDeviceDescriptor(request.deviceId);
      case 'getConfigDescriptor':
        return usbarcDdk.getConfigDescriptor(request.deviceId, request.configurationValue);
      case 'claimInterface':
        return usbarcDdk.claimInterface(request.deviceId, request.interfaceNumber);
      case 'releaseInterface':
        return { status: usbarcDdk.releaseInterface(request.handle) } as DdkStatusResponse;
      case 'selectInterfaceSetting':
        return { status: usbarcDdk.selectInterfaceSetting(request.handle, request.alternateSetting) } as DdkStatusResponse;
      case 'controlTransfer':
        return usbarcDdk.controlTransfer(request.deviceId, request.setup, request.data, request.timeoutMs);
      case 'claimedControlTransfer':
        return usbarcDdk.claimedControlTransfer(request.handle, request.setup, request.data, request.timeoutMs);
      case 'pipeTransfer':
        return usbarcDdk.pipeTransfer(request.handle, request.endpointAddress, request.data, request.timeoutMs);
      default:
        return { status: -22, error: 'Unsupported DDK RPC operation' } as DdkStatusResponse;
    }
  }
}

export default class UsbArcDriverExtensionAbility extends DriverExtensionAbility {
  private initialized: boolean = false;

  onInit(want: Want): void {
    void want;
    const status: number = usbarcDdk.init();
    this.initialized = status === 0;
    console.info(`USBArc DDK init status=${status}`);
  }

  onRelease(): void {
    if (this.initialized) {
      const status: number = usbarcDdk.release();
      console.info(`USBArc DDK release status=${status}`);
    }
    this.initialized = false;
  }

  onConnect(want: Want): rpc.RemoteObject {
    void want;
    if (!this.initialized) {
      console.error('USBArc DDK extension connected while DDK initialization is unavailable');
    }
    return new DriverRemoteStub('io.github.rockymtnwolf.usbarc.ddk.DriverRemoteStub');
  }

  onDisconnect(want: Want): void {
    void want;
  }
}
