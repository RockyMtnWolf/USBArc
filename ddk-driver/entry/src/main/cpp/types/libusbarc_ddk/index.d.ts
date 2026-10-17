declare module 'libusbarc_ddk.so' {
  interface DdkResult {
    status: number;
    value?: Object;
  }
  interface DdkDeviceDescriptor {
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
  interface DdkConfigDescriptor {
    configurationValue: number;
    attributes: number;
    maxPower: number;
    interfaceCount: number;
    bytes: Array<number>;
  }
  interface DdkTransferResult {
    status: number;
    actualLength: number;
    data: Array<number>;
  }
  interface UsbArcDdkModule {
    init(): number;
    isInitialized(): boolean;
    release(): number;
    getDevices(): DdkResult;
    getDeviceDescriptor(deviceId: string): DdkResult;
    getConfigDescriptor(deviceId: string, configurationValue: number): DdkResult;
    claimInterface(deviceId: string, interfaceNumber: number): DdkResult;
    releaseInterface(handle: string): number;
    selectInterfaceSetting(handle: string, alternateSetting: number): number;
    controlTransfer(deviceId: string, setup: Array<number>, data: Array<number>, timeoutMs: number): DdkTransferResult;
    claimedControlTransfer(handle: string, setup: Array<number>, data: Array<number>, timeoutMs: number): DdkTransferResult;
    pipeTransfer(handle: string, endpointAddress: number, data: Array<number>, timeoutMs: number): DdkTransferResult;
  }
  const usbarcDdk: UsbArcDdkModule;
  export default usbarcDdk;
}
