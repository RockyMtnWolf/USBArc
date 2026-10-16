declare module 'libusbip_native.so' {
  interface UsbIpNativeModule {
    getUsbSpeed(fd: number): number;
    getInterfaceAddresses(): Array<NativeNetworkAddress>;
    getListenerSocketInfo(fd: number): NativeListenerSocketInfo;
  }
  interface NativeNetworkAddress {
    address: string;
    interfaceName: string;
    family: number;
    prefixLength: number;
    scopeId: number;
    isLoopback: boolean;
    isUp: boolean;
    isRunning: boolean;
  }
  interface NativeListenerSocketInfo {
    family: number;
    port: number;
    /** 0 dual stack, 1 IPv6 only, -1 could not be queried. */
    ipv6Only: number;
  }
  const usbipNative: UsbIpNativeModule;
  export default usbipNative;
}
