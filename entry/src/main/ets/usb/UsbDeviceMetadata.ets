/** USBManager display fields copied without opening, requesting, or claiming a device. */
export interface UsbManagerDeviceMetadata {
  vendorId: number;
  productId: number;
  busNum: number;
  devAddress: number;
  manufacturerName: string;
  productName: string;
  serialNumber: string;
}

export interface UsbPhysicalAddress {
  busNum: number;
  devAddress: number;
}

export interface UsbDisplayMetadata {
  manufacturer: string;
  product: string;
  serialNumber: string;
}

function fixedHex(value: string, digits: number): number {
  if (value.length !== digits) return -1;
  let parsed: number = 0;
  for (let index: number = 0; index < value.length; index++) {
    const code: number = value.toUpperCase().charCodeAt(index);
    let digit: number = -1;
    if (code >= 0x30 && code <= 0x39) digit = code - 0x30;
    else if (code >= 0x41 && code <= 0x46) digit = code - 0x41 + 10;
    if (digit < 0) return -1;
    parsed = parsed * 16 + digit;
  }
  return parsed;
}

/**
 * Parses a complete DeviceManager USB hardware ID and verifies its VID/PID.
 * BUS and DEV components are hexadecimal in this OS-provided description.
 */
export function parseDdkUsbPhysicalAddress(
  description: string, vendorId: number, productId: number
): UsbPhysicalAddress | undefined {
  if (description.length === 0 || description.length > 128) return undefined;
  const tokens: Array<string> = description.toUpperCase().split('&');
  if (tokens.length !== 6 || tokens[0] !== 'USB') return undefined;
  let busNum: number = -1;
  let devAddress: number = -1;
  let parsedVendor: number = -1;
  let parsedProduct: number = -1;
  let sawBus: boolean = false;
  let sawDevice: boolean = false;
  let sawVendor: boolean = false;
  let sawProduct: boolean = false;
  let sawClass: boolean = false;
  for (let index: number = 1; index < tokens.length; index++) {
    const token: string = tokens[index];
    const separator: number = token.indexOf('_');
    if (separator <= 0 || separator !== token.lastIndexOf('_')) return undefined;
    const key: string = token.substring(0, separator);
    const value: string = token.substring(separator + 1);
    if (key === 'BUS' && !sawBus) {
      busNum = fixedHex(value, 2);
      sawBus = true;
    } else if (key === 'DEV' && !sawDevice) {
      devAddress = fixedHex(value, 2);
      sawDevice = true;
    } else if (key === 'VID' && !sawVendor) {
      parsedVendor = fixedHex(value, 4);
      sawVendor = true;
    } else if (key === 'PID' && !sawProduct) {
      parsedProduct = fixedHex(value, 4);
      sawProduct = true;
    } else if (key === 'CLASS' && !sawClass) {
      if (fixedHex(value, 2) < 0) return undefined;
      sawClass = true;
    } else {
      return undefined;
    }
    if ((sawBus && busNum < 0) || (sawDevice && devAddress < 1) ||
      (sawVendor && parsedVendor < 0) || (sawProduct && parsedProduct < 0)) return undefined;
  }
  if (!sawBus || !sawDevice || !sawVendor || !sawProduct || !sawClass ||
    parsedVendor !== vendorId || parsedProduct !== productId || devAddress > 127) return undefined;
  return { busNum, devAddress };
}

/**
 * Uses physical location when the system supplied a complete USB hardware ID.
 * If no reliable location is available, VID/PID is accepted only when unique.
 */
export function selectUsbManagerMetadata(
  vendorId: number,
  productId: number,
  description: string,
  candidates: ReadonlyArray<UsbManagerDeviceMetadata>
): UsbManagerDeviceMetadata | undefined {
  const location: UsbPhysicalAddress | undefined = parseDdkUsbPhysicalAddress(description, vendorId, productId);
  const matches: Array<UsbManagerDeviceMetadata> = candidates.filter(
    (candidate: UsbManagerDeviceMetadata): boolean => candidate.vendorId === vendorId && candidate.productId === productId);
  if (location !== undefined) {
    const exact: Array<UsbManagerDeviceMetadata> = matches.filter((candidate: UsbManagerDeviceMetadata): boolean =>
      candidate.busNum === location.busNum && candidate.devAddress === location.devAddress);
    return exact.length === 1 ? exact[0] : undefined;
  }
  return matches.length === 1 ? matches[0] : undefined;
}

function clean(value: string | undefined): string {
  return value === undefined ? '' : value.trim();
}

/** USBManager metadata takes priority; DDK descriptor strings are fallback values. */
export function mergeUsbDisplayMetadata(
  manager: UsbManagerDeviceMetadata | undefined,
  fallback: UsbDisplayMetadata
): UsbDisplayMetadata {
  return {
    manufacturer: clean(manager?.manufacturerName) || clean(fallback.manufacturer),
    product: clean(manager?.productName) || clean(fallback.product),
    serialNumber: clean(manager?.serialNumber) || clean(fallback.serialNumber)
  };
}
