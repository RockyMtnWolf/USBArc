import { usbManager } from '@kit.BasicServicesKit';

/** The descriptor fields used to identify a USB hub without VID/PID heuristics. */
export interface UsbHubInterfaceDescriptor {
  readonly clazz: number;
}

export interface UsbHubConfigurationDescriptor {
  readonly interfaces: ReadonlyArray<UsbHubInterfaceDescriptor>;
}

export interface UsbHubDeviceDescriptor {
  readonly vendorId: number;
  readonly productId: number;
  readonly clazz: number;
  readonly configs: ReadonlyArray<UsbHubConfigurationDescriptor>;
}

export function usbManagerHubDescriptor(device: Readonly<usbManager.USBDevice>): UsbHubDeviceDescriptor {
  const configs: Array<UsbHubConfigurationDescriptor> = device.configs.map(
    (config: usbManager.USBConfiguration): UsbHubConfigurationDescriptor => {
      const interfaces: Array<UsbHubInterfaceDescriptor> = config.interfaces.map(
        (iface: usbManager.USBInterface): UsbHubInterfaceDescriptor => ({ clazz: iface.clazz }));
      return { interfaces };
    });
  return { vendorId: device.vendorId, productId: device.productId, clazz: device.clazz, configs };
}

/** True only when the device descriptor proves this is a hub. */
export function isProvableUsbHub(device: UsbHubDeviceDescriptor): boolean {
  if (device.clazz === 0x09) return true;
  if (device.clazz !== 0 || device.configs.length === 0) return false;

  let foundInterface: boolean = false;
  for (let configIndex: number = 0; configIndex < device.configs.length; configIndex++) {
    const config: UsbHubConfigurationDescriptor = device.configs[configIndex];
    if (config.interfaces.length === 0) return false;
    for (let interfaceIndex: number = 0; interfaceIndex < config.interfaces.length; interfaceIndex++) {
      if (config.interfaces[interfaceIndex].clazz !== 0x09) return false;
      foundInterface = true;
    }
  }
  return foundInterface;
}

/**
 * DDK's unbound rows have no class descriptor. Hide one only when every
 * USBManager row with the same VID/PID independently proves it is a hub.
 */
export function shouldHideDdkHubRow(
  vendorId: number, productId: number, managerDevices: ReadonlyArray<UsbHubDeviceDescriptor>
): boolean {
  let matchCount: number = 0;
  for (let index: number = 0; index < managerDevices.length; index++) {
    const candidate: UsbHubDeviceDescriptor = managerDevices[index];
    if (candidate.vendorId !== vendorId || candidate.productId !== productId) continue;
    matchCount++;
    if (!isProvableUsbHub(candidate)) return false;
  }
  return matchCount > 0;
}
