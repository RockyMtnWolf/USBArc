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

function parseFixedHex(value: string, expectedLength: number): number {
  if (value.length !== expectedLength) return -1;
  let parsed: number = 0;
  for (let index: number = 0; index < value.length; index++) {
    const code: number = value.charCodeAt(index);
    let digit: number = -1;
    if (code >= 0x30 && code <= 0x39) digit = code - 0x30;
    else if (code >= 0x41 && code <= 0x46) digit = code - 0x41 + 10;
    if (digit < 0) return -1;
    parsed = parsed * 16 + digit;
  }
  return parsed;
}

/** Parses the complete OS USB identifier and cross-checks its VID/PID. */
export function shouldHideDdkSystemDescription(description: string, vendorId: number, productId: number): boolean {
  if (description.length === 0 || description.length > 128) return false;
  const tokens: Array<string> = description.toUpperCase().split('&');
  if (tokens.length !== 6 || tokens[0] !== 'USB') return false;

  let busNumber: number = -1;
  let deviceAddress: number = -1;
  let encodedProductId: number = -1;
  let encodedVendorId: number = -1;
  let deviceClass: number = -1;
  let seenBus: boolean = false;
  let seenDevice: boolean = false;
  let seenProduct: boolean = false;
  let seenVendor: boolean = false;
  let seenClass: boolean = false;

  for (let index: number = 1; index < tokens.length; index++) {
    const token: string = tokens[index];
    const separator: number = token.indexOf('_');
    if (separator <= 0 || separator !== token.lastIndexOf('_')) return false;
    const key: string = token.substring(0, separator);
    const value: string = token.substring(separator + 1);
    if (key === 'BUS') {
      if (seenBus) return false;
      busNumber = parseFixedHex(value, 2);
      seenBus = true;
    } else if (key === 'DEV') {
      if (seenDevice) return false;
      deviceAddress = parseFixedHex(value, 2);
      seenDevice = true;
    } else if (key === 'PID') {
      if (seenProduct) return false;
      encodedProductId = parseFixedHex(value, 4);
      seenProduct = true;
    } else if (key === 'VID') {
      if (seenVendor) return false;
      encodedVendorId = parseFixedHex(value, 4);
      seenVendor = true;
    } else if (key === 'CLASS') {
      if (seenClass) return false;
      deviceClass = parseFixedHex(value, 2);
      seenClass = true;
    } else {
      return false;
    }
    if ((seenBus && busNumber < 0) || (seenDevice && deviceAddress < 0) ||
      (seenProduct && encodedProductId < 0) || (seenVendor && encodedVendorId < 0) ||
      (seenClass && deviceClass < 0)) return false;
  }

  return seenBus && seenDevice && seenProduct && seenVendor && seenClass &&
    busNumber >= 0 && deviceAddress >= 1 && deviceAddress <= 127 &&
    encodedVendorId === vendorId && encodedProductId === productId && deviceClass === 0x09;
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
