declare module 'libusbarc_ddk.so' {
  interface DdkNativeResult {
    status: number;
    value?: Object;
  }
  interface DdkNativeTransferResult {
    status: number;
    actualLength: number;
    data: Array<number>;
  }
  interface DdkNativeModule {
    init(): number;
    isInitialized(): boolean;
    release(): number;
    getDevices(): DdkNativeResult;
    getDeviceDescriptor(deviceId: string): DdkNativeResult;
    getActiveConfiguration(deviceId: string): DdkNativeResult;
    /** Resolves a USB configuration descriptor index to its bConfigurationValue before using the DDK API. */
    getConfigDescriptor(deviceId: string, descriptorIndex: number): DdkNativeResult;
    claimInterface(deviceId: string, interfaceNumber: number): DdkNativeResult;
    releaseInterface(handle: string): number;
    selectInterfaceSetting(handle: string, settingIndex: number): number;
    controlTransfer(deviceId: string, setup: Array<number>, data: Array<number>, timeoutMs: number): DdkNativeTransferResult;
    claimedControlTransfer(handle: string, setup: Array<number>, data: Array<number>, timeoutMs: number): DdkNativeTransferResult;
    pipeTransfer(handle: string, endpointAddress: number, data: Array<number>, timeoutMs: number): DdkNativeTransferResult;
  }
  const ddk: DdkNativeModule;
  export default ddk;
}
