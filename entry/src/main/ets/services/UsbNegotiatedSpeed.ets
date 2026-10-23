import { usbManager } from '@kit.BasicServicesKit';
import usbipNative from 'libusbip_native.so';
import { UsbPhysicalAddress } from '../usb/UsbDeviceMetadata';

const PERMISSION_POLL_INTERVAL_MS: number = 200;
const PERMISSION_POLL_LIMIT: number = 40;

/** Stable USBManager identity used to reject ambiguous VID/PID matches and hotplug swaps. */
export interface UsbNegotiatedSpeedDeviceIdentity {
  readonly vendorId: number;
  readonly productId: number;
  readonly busNum: number;
  readonly devAddress: number;
  readonly name: string;
}

/** Returns the only VID/PID match, or -1 when absent or ambiguous. */
export function selectUniqueUsbSpeedDeviceIndex(
  devices: ReadonlyArray<UsbNegotiatedSpeedDeviceIdentity>, vendorId: number, productId: number,
  physicalIdentity?: UsbPhysicalAddress
): number {
  let matchIndex: number = -1;
  for (let index: number = 0; index < devices.length; index++) {
    const candidate: UsbNegotiatedSpeedDeviceIdentity = devices[index];
    if (candidate.vendorId !== vendorId || candidate.productId !== productId) continue;
    if (physicalIdentity !== undefined && (candidate.busNum !== physicalIdentity.busNum ||
      candidate.devAddress !== physicalIdentity.devAddress)) continue;
    if (matchIndex >= 0) return -1;
    matchIndex = index;
  }
  return matchIndex;
}

/** Device name plus USB bus/device addresses must remain unchanged across the read. */
export function sameUsbSpeedDeviceIdentity(
  left: UsbNegotiatedSpeedDeviceIdentity, right: UsbNegotiatedSpeedDeviceIdentity
): boolean {
  return left.vendorId === right.vendorId && left.productId === right.productId &&
    left.busNum === right.busNum && left.devAddress === right.devAddress && left.name === right.name;
}

function waitForPermissionPoll(): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => { resolve(); }, PERMISSION_POLL_INTERVAL_MS);
  });
}

/**
 * Reads the negotiated USB bus speed through the temporary USBManager pipe.
 * This operation never claims an interface or submits a transfer. It requests
 * OS permission only when allowRequest is explicitly true.
 * Returns USB/IP speed 1..6, or 0 when permission/device identity/speed is unknown.
 */
export async function readUsbNegotiatedSpeed(
  vendorId: number, productId: number, allowRequest: boolean,
  physicalIdentity?: UsbPhysicalAddress
): Promise<number> {
  let initialDevices: Array<Readonly<usbManager.USBDevice>>;
  try {
    initialDevices = usbManager.getDevices();
  } catch (_error) {
    return 0;
  }
  const initialIndex: number = selectUniqueUsbSpeedDeviceIndex(initialDevices, vendorId, productId, physicalIdentity);
  if (initialIndex < 0) return 0;
  const initialDevice: Readonly<usbManager.USBDevice> = initialDevices[initialIndex];

  let authorized: boolean = false;
  try {
    authorized = usbManager.hasRight(initialDevice.name);
  } catch (_error) {
    return 0;
  }
  if (!authorized) {
    if (!allowRequest) return 0;
    let beforePermission: Array<Readonly<usbManager.USBDevice>>;
    try {
      beforePermission = usbManager.getDevices();
    } catch (_error) {
      return 0;
    }
    const beforePermissionIndex: number = selectUniqueUsbSpeedDeviceIndex(beforePermission, vendorId, productId,
      physicalIdentity);
    if (beforePermissionIndex < 0 ||
      !sameUsbSpeedDeviceIdentity(initialDevice, beforePermission[beforePermissionIndex])) return 0;

    let accepted: boolean = false;
    try {
      accepted = await usbManager.requestRight(beforePermission[beforePermissionIndex].name);
    } catch (_error) {
      return 0;
    }
    if (!accepted) return 0;

    authorized = false;
    for (let attempt: number = 0; attempt < PERMISSION_POLL_LIMIT; attempt++) {
      await waitForPermissionPoll();
      let currentDevices: Array<Readonly<usbManager.USBDevice>>;
      try {
        currentDevices = usbManager.getDevices();
      } catch (_error) {
        return 0;
      }
      const currentIndex: number = selectUniqueUsbSpeedDeviceIndex(currentDevices, vendorId, productId,
        physicalIdentity);
      if (currentIndex < 0 || !sameUsbSpeedDeviceIdentity(initialDevice, currentDevices[currentIndex])) return 0;
      try {
        authorized = usbManager.hasRight(currentDevices[currentIndex].name);
      } catch (_error) {
        return 0;
      }
      if (authorized) break;
    }
    if (!authorized) return 0;
  }

  // Re-enumerate immediately before connecting so a stale manager object is never used.
  let beforeRead: Array<Readonly<usbManager.USBDevice>>;
  try {
    beforeRead = usbManager.getDevices();
  } catch (_error) {
    return 0;
  }
  const beforeIndex: number = selectUniqueUsbSpeedDeviceIndex(beforeRead, vendorId, productId, physicalIdentity);
  if (beforeIndex < 0 || !sameUsbSpeedDeviceIdentity(initialDevice, beforeRead[beforeIndex])) return 0;
  const device: Readonly<usbManager.USBDevice> = beforeRead[beforeIndex];
  try {
    if (!usbManager.hasRight(device.name)) return 0;
  } catch (_error) {
    return 0;
  }

  let pipe: usbManager.USBDevicePipe | undefined = undefined;
  try {
    pipe = usbManager.connectDevice(device);
    if (pipe === undefined) return 0;
    const fd: number = usbManager.getFileDescriptor(pipe);
    if (!Number.isFinite(fd) || fd < 0) return 0;
    const speed: number = usbipNative.getUsbSpeed(fd);
    if (!Number.isInteger(speed) || speed < 1 || speed > 6) return 0;

    // Reject a disconnect/reconnect or replacement that happened during the native query.
    const afterRead: Array<Readonly<usbManager.USBDevice>> = usbManager.getDevices();
    const afterIndex: number = selectUniqueUsbSpeedDeviceIndex(afterRead, vendorId, productId, physicalIdentity);
    if (afterIndex < 0 || !sameUsbSpeedDeviceIdentity(device, afterRead[afterIndex])) return 0;
    return speed;
  } catch (_error) {
    return 0;
  } finally {
    if (pipe !== undefined) {
      try {
        usbManager.closePipe(pipe);
      } catch (_error) {
        // The read result does not imply ownership of a persistent USB handle.
      }
    }
  }
}
