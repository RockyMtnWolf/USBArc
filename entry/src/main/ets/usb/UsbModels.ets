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
  endpoints: Array<UsbEndpointInfo>;
}

export interface UsbConfigurationInfo {
  id: number;
  attributes: number;
  maxPower: number;
  interfaces: Array<UsbInterfaceInfo>;
  raw: usbManager.USBConfiguration;
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
  /** Third-party apps cannot read serial via getDevices; empty unless the platform supplies it. */
  serialNumber: string;
  version: string;
  deviceClass: number;
  deviceSubClass: number;
  deviceProtocol: number;
  configurations: Array<UsbConfigurationInfo>;
  authorized: boolean;
  shared: boolean;
  available: boolean;
}

export interface UsbIpServerSettings {
  host: string;
  port: number;
  autoRequestPermission: boolean;
  autoShare: boolean;
  maxClients: number;
  forceClaim: boolean;
}

export interface UsbIpServerStatus {
  running: boolean;
  host: string;
  port: number;
  clientCount: number;
  sharedDeviceIds: Array<string>;
  lastError: string;
}

export type UsbIpServerEventKind = 'devices' | 'status' | 'client' | 'error';

export interface UsbIpServerEvent {
  kind: UsbIpServerEventKind;
  message: string;
  devices: Array<UsbDeviceInfo>;
  status: UsbIpServerStatus;
}

export interface UsbDeviceHandle {
  device: usbManager.USBDevice;
  pipe: usbManager.USBDevicePipe;
  info: UsbDeviceInfo;
  claimedInterfaces: Array<usbManager.USBInterface>;
  activeConfigurationId: number;
  activeAlternates: Map<number, number>;
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
