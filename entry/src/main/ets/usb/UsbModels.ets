import { usbManager } from '@kit.BasicServicesKit';

export interface UsbEndpointInfo {
  address: number;
  attributes: number;
  interval: number;
  maxPacketSize: number;
  direction: number;
  number: number;
  type: number;
  interfaceId: number;
}

export interface UsbInterfaceInfo {
  id: number;
  protocol: number;
  clazz: number;
  subClass: number;
  alternateSetting: number;
  /** DDK descriptor-order index required by OH_Usb_SelectInterfaceSetting. */
  settingIndex?: number;
  endpoints: Array<UsbEndpointInfo>;
}

export interface UsbConfigurationInfo {
  /** Physical configuration value exposed by the descriptor. */
  id: number;
  /** Descriptor index used by DDK APIs; undefined for usbManager-only rows. */
  index?: number;
  attributes: number;
  maxPower: number;
  interfaces: Array<UsbInterfaceInfo>;
  /** Present only for usbManager handles; DDK descriptors are never cast to manager objects. */
  raw?: usbManager.USBConfiguration;
}

export interface UsbDeviceInfo {
  id: string;
  name: string;
  path: string;
  busId: string;
  busNum: number;
  devAddress: number;
  vendorId: number;
  productId: number;
  /** USB/IP speed enum; 0 means the platform did not expose it. */
  speed: number;
  manufacturer: string;
  product: string;
  /** Empty unless the selected backend exposes a readable USB serial descriptor. */
  serialNumber: string;
  version: string;
  deviceClass: number;
  deviceSubClass: number;
  deviceProtocol: number;
  configurations: Array<UsbConfigurationInfo>;
  /** DDK physical ID encoded from USBManager bus and device address. */
  backendDeviceId?: number;
  /** Decimal uint64 DDK device ID used for descriptor and transfer calls. */
  opaqueDeviceId?: string;
  /** True only after the selected backend confirms access (manager right or initialized DDK binding). */
  authorized: boolean;
  /** True only while this app holds a claimed USB interface handle. */
  occupied: boolean;
  /** Shared is server export policy; it does not imply an interface is claimed. */
  shared: boolean;
  /** True while a USB/IP client owns this device import session. */
  imported: boolean;
  /** True while a previous connection's USB transfers are draining; this device cannot be reused yet. */
  closing: boolean;
  available: boolean;
}

export interface UsbIpServerSettings {
  backendMode: UsbBackendMode;
  host: string;
  port: number;
  autoRequestPermission: boolean;
  autoShare: boolean;
  maxClients: number;
  forceClaim: boolean;
  retainClaimsOnStop: boolean;
}

export type UsbBackendMode = 'usbManager' | 'usbDdk';

export interface UsbIpServerStatus {
  running: boolean;
  host: string;
  port: number;
  clientCount: number;
  sharedDeviceIds: Array<string>;
  occupiedDeviceIds: Array<string>;
  listenerFamilies: Array<'IPv4' | 'IPv6'>;
  lastError: string;
}

export type UsbIpServerEventKind = 'devices' | 'status' | 'client' | 'error';

export interface UsbIpServerEvent {
  kind: UsbIpServerEventKind;
  message: string;
  devices: Array<UsbDeviceInfo>;
  status: UsbIpServerStatus;
}

export interface UsbDeviceHandleBase {
  info: UsbDeviceInfo;
  activeConfigurationId: number;
  activeAlternates: Map<number, number>;
  claimedInterfaces: Array<number>;
}

export interface UsbManagerDeviceHandle extends UsbDeviceHandleBase {
  backendMode: 'usbManager';
  device: usbManager.USBDevice;
  pipe: usbManager.USBDevicePipe;
  claimedRawInterfaces: Array<usbManager.USBInterface>;
}

export interface UsbDdkDeviceHandle extends UsbDeviceHandleBase {
  backendMode: 'usbDdk';
  systemDeviceId: number;
  opaqueDeviceId: string;
  claimTokens: Map<number, string>;
}

export type UsbDeviceHandle = UsbManagerDeviceHandle | UsbDdkDeviceHandle;

export function claimedInterfaceCount(handle: UsbDeviceHandle): number {
  return handle.claimedInterfaces.length;
}

export interface UsbTransferResult {
  data: Uint8Array;
  actualLength: number;
  status: number;
}

export interface UsbControlTransferResult {
  data: Uint8Array;
  actualLength: number;
}

export interface UsbTransferOperation {
  promise: Promise<UsbTransferResult>;
  /** Returns true only when cancellation was requested before completion. */
  cancel: () => boolean;
}

export function makeDeviceId(device: usbManager.USBDevice): string {
  return `${device.busNum}-${device.devAddress}`;
}
