declare module 'libusbip_native.so' {
  interface UsbIpNativeModule {
    getUsbSpeed(fd: number): number;
  }
  const usbipNative: UsbIpNativeModule;
  export default usbipNative;
}
