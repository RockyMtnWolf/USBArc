import { BusinessError, usbManager } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import usbipNative from 'libusbip_native.so';
import {
  UsbConfigurationInfo,
  UsbDeviceHandle,
  UsbDeviceInfo,
  UsbEndpointInfo,
  UsbInterfaceInfo,
  UsbControlTransferResult,
  UsbTransferOperation,
  UsbTransferResult,
  makeDeviceId
} from './UsbModels';

const USB_LOG_DOMAIN: number = 0x0000;
const USB_LOG_TAG: string = 'UsbManagerBackend';
const USB_PERMISSION_POLL_INTERVAL_MS: number = 200;
const USB_PERMISSION_POLL_LIMIT: number = 40;

export class UsbBackendError extends Error {
  status: number;

  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

function asNumber(value: number): number {
  return Number.isFinite(value) ? Math.max(0, Math.floor(value)) : 0;
}

function mapDevice(device: usbManager.USBDevice): UsbDeviceInfo {
  const configs: Array<UsbConfigurationInfo> = [];
  device.configs.forEach((config: usbManager.USBConfiguration) => {
    const interfaces: Array<UsbInterfaceInfo> = [];
    config.interfaces.forEach((iface: usbManager.USBInterface) => {
      const endpoints: Array<UsbEndpointInfo> = [];
      iface.endpoints.forEach((endpoint: usbManager.USBEndpoint) => {
        endpoints.push({
          address: asNumber(endpoint.address),
          attributes: asNumber(endpoint.attributes),
          interval: asNumber(endpoint.interval),
          maxPacketSize: asNumber(endpoint.maxPacketSize),
          direction: asNumber(endpoint.direction),
          number: asNumber(endpoint.number),
          type: asNumber(endpoint.type),
          interfaceId: asNumber(endpoint.interfaceId)
        });
      });
      interfaces.push({
        id: asNumber(iface.id), protocol: asNumber(iface.protocol), clazz: asNumber(iface.clazz),
        subClass: asNumber(iface.subClass), alternateSetting: asNumber(iface.alternateSetting), endpoints
      });
    });
    configs.push({
      id: asNumber(config.id), attributes: asNumber(config.attributes), maxPower: asNumber(config.maxPower),
      interfaces, raw: config
    });
  });
  const id: string = makeDeviceId(device);
  return {
    id,
    name: device.name,
    path: `/sys/devices/usb/${device.busNum}-${device.devAddress}`,
    busId: `${device.busNum}-${device.devAddress}`,
    busNum: asNumber(device.busNum),
    devAddress: asNumber(device.devAddress),
    vendorId: asNumber(device.vendorId),
    productId: asNumber(device.productId),
    speed: 0,
    manufacturer: device.manufacturerName,
    product: device.productName,
    serialNumber: device.serial ?? '',
    version: device.version,
    deviceClass: asNumber(device.clazz),
    deviceSubClass: asNumber(device.subClass),
    deviceProtocol: asNumber(device.protocol),
    configurations: configs,
    authorized: usbManager.hasRight(device.name),
    occupied: false,
    shared: false,
    imported: false,
    closing: false,
    available: true
  };
}

function businessErrorCode(error: Object): number {
  const item: BusinessError = error as BusinessError;
  return item.code;
}

export class UsbManagerBackend {
  private handles: Map<string, UsbDeviceHandle> = new Map<string, UsbDeviceHandle>();
  private closingIds: Set<string> = new Set<string>();
  private sharedIds: Set<string> = new Set<string>();
  private serialCache: Map<string, string> = new Map<string, string>();
  private serialProbed: Set<string> = new Set<string>();
  private speedCache: Map<string, number> = new Map<string, number>();

  listDevices(): Array<UsbDeviceInfo> {
    const devices: Array<usbManager.USBDevice> = usbManager.getDevices();
    return devices.map((device: usbManager.USBDevice): UsbDeviceInfo => {
      const info: UsbDeviceInfo = mapDevice(device);
      info.serialNumber = this.serialCache.get(info.id) ?? info.serialNumber;
      info.speed = this.querySpeed(device);
      info.shared = this.sharedIds.has(info.id);
      const heldHandle: UsbDeviceHandle | undefined = this.handles.get(info.id);
      info.occupied = heldHandle !== undefined && heldHandle.claimedInterfaces.length > 0;
      info.closing = this.closingIds.has(info.id);
      info.available = true;
      return info;
    });
  }

  async requestPermission(deviceId: string): Promise<boolean> {
    const device: usbManager.USBDevice | undefined = usbManager.getDevices().find(
      (item: usbManager.USBDevice): boolean => makeDeviceId(item) === deviceId
    );
    if (device === undefined) {
      throw new UsbBackendError('USB device disconnected before permission request', -19);
    }
    try {
      const rightBefore: boolean = usbManager.hasRight(device.name);
      hilog.info(USB_LOG_DOMAIN, USB_LOG_TAG,
        'Permission request begin id=%{public}s name=%{public}s bus=%{public}d address=%{public}d right=%{public}d',
        deviceId, device.name, device.busNum, device.devAddress, rightBefore ? 1 : 0);
      const accepted: boolean = rightBefore ? true : await usbManager.requestRight(device.name);
      let refreshedDevice: usbManager.USBDevice | undefined = this.findDevice(deviceId);
      let refreshedRight: boolean = refreshedDevice === undefined ? false : usbManager.hasRight(refreshedDevice.name);
      if (accepted && !refreshedRight) {
        for (let attempt: number = 0; attempt < USB_PERMISSION_POLL_LIMIT && !refreshedRight; attempt++) {
          await new Promise<void>((resolve): void => {
            setTimeout((): void => { resolve(); }, USB_PERMISSION_POLL_INTERVAL_MS);
          });
          refreshedDevice = this.findDevice(deviceId);
          refreshedRight = refreshedDevice === undefined ? false : usbManager.hasRight(refreshedDevice.name);
        }
      }
      hilog.info(USB_LOG_DOMAIN, USB_LOG_TAG,
        'Permission request end id=%{public}s granted=%{public}d oldName=%{public}s oldRight=%{public}d newName=%{public}s newRight=%{public}d',
        deviceId, accepted ? 1 : 0, device.name, usbManager.hasRight(device.name) ? 1 : 0,
        refreshedDevice === undefined ? '<missing>' : refreshedDevice.name, refreshedRight ? 1 : 0);
      if (refreshedRight && refreshedDevice !== undefined) {
        this.speedCache.delete(deviceId);
        if (!this.handles.has(deviceId)) {
          this.serialProbed.add(deviceId);
          const serial: string = await this.readSerialNumber(refreshedDevice);
          if (serial.length > 0) this.serialCache.set(deviceId, serial);
        }
        const afterSerialDevice: usbManager.USBDevice | undefined = this.findDevice(deviceId);
        const rightAfterSerial: boolean = afterSerialDevice === undefined ? false : usbManager.hasRight(afterSerialDevice.name);
        hilog.info(USB_LOG_DOMAIN, USB_LOG_TAG,
          'Permission metadata serial phase id=%{public}s name=%{public}s right=%{public}d',
          deviceId, afterSerialDevice === undefined ? '<missing>' : afterSerialDevice.name, rightAfterSerial ? 1 : 0);
        this.querySpeed(refreshedDevice);
        const afterSpeedDevice: usbManager.USBDevice | undefined = this.findDevice(deviceId);
        const rightAfterSpeed: boolean = afterSpeedDevice === undefined ? false : usbManager.hasRight(afterSpeedDevice.name);
        hilog.info(USB_LOG_DOMAIN, USB_LOG_TAG,
          'Permission metadata speed phase id=%{public}s name=%{public}s right=%{public}d',
          deviceId, afterSpeedDevice === undefined ? '<missing>' : afterSpeedDevice.name, rightAfterSpeed ? 1 : 0);
        if (rightAfterSerial && rightAfterSpeed && afterSpeedDevice !== undefined) return true;
        if (accepted) {
          throw new UsbBackendError(
            '系统已收到 USB 授权请求，但读取设备信息后访问权未确认；请刷新设备列表。', -13);
        }
        return false;
      }
      if (accepted) {
        throw new UsbBackendError(
          '系统已收到 USB 授权请求，但尚未确认设备访问权；请完成系统弹窗后刷新设备列表。', -13);
      }
      return false;
    } catch (error) {
      if (error instanceof UsbBackendError) throw error;
      throw new UsbBackendError(`USB permission request failed (${businessErrorCode(error as Object)})`, -13);
    }
  }

  private findDevice(deviceId: string): usbManager.USBDevice | undefined {
    return usbManager.getDevices().find((item: usbManager.USBDevice): boolean => makeDeviceId(item) === deviceId);
  }

  addShared(deviceId: string): void {
    if (usbManager.getDevices().find((item: usbManager.USBDevice): boolean => makeDeviceId(item) === deviceId) === undefined) {
      throw new UsbBackendError('USB device is no longer connected', -19);
    }
    const device: usbManager.USBDevice | undefined = usbManager.getDevices().find(
      (item: usbManager.USBDevice): boolean => makeDeviceId(item) === deviceId
    );
    if (device === undefined || !usbManager.hasRight(device.name)) {
      throw new UsbBackendError('USB access permission is required before sharing', -13);
    }
    this.sharedIds.add(deviceId);
  }

  removeShared(deviceId: string): void {
    this.sharedIds.delete(deviceId);
    this.closeDevice(deviceId);
  }

  isShared(deviceId: string): boolean {
    return this.sharedIds.has(deviceId);
  }

  getSharedDeviceIds(): Array<string> {
    return Array.from(this.sharedIds);
  }

  markDeviceClosing(deviceId: string): void {
    this.closingIds.add(deviceId);
  }

  clearDeviceClosing(deviceId: string): void {
    this.closingIds.delete(deviceId);
  }

  hasClosingDevices(): boolean {
    return this.closingIds.size > 0;
  }

  isDeviceClosing(deviceId: string): boolean {
    return this.closingIds.has(deviceId);
  }

  pruneMissingDevices(): Array<string> {
    const connected: Set<string> = new Set<string>(usbManager.getDevices().map(
      (device: usbManager.USBDevice): string => makeDeviceId(device)
    ));
    const removed: Array<string> = [];
    this.sharedIds.forEach((id: string) => { if (!connected.has(id)) removed.push(id); });
    const staleMetadata: Array<string> = [];
    this.serialCache.forEach((_serial: string, id: string) => { if (!connected.has(id)) staleMetadata.push(id); });
    this.speedCache.forEach((_speed: number, id: string) => { if (!connected.has(id) && !staleMetadata.includes(id)) staleMetadata.push(id); });
    this.serialProbed.forEach((id: string) => { if (!connected.has(id) && !staleMetadata.includes(id)) staleMetadata.push(id); });
    staleMetadata.forEach((id: string) => {
      this.serialCache.delete(id);
      this.speedCache.delete(id);
      this.serialProbed.delete(id);
      if (!this.sharedIds.has(id)) this.closeDevice(id);
    });
    removed.forEach((id: string) => {
      this.sharedIds.delete(id);
    });
    return removed;
  }

  async refreshMetadata(): Promise<void> {
    const devices: Array<usbManager.USBDevice> = usbManager.getDevices();
    for (let index: number = 0; index < devices.length; index++) {
      const device: usbManager.USBDevice = devices[index];
      if (!usbManager.hasRight(device.name)) {
        hilog.info(USB_LOG_DOMAIN, USB_LOG_TAG,
          'Metadata refresh sees no USB right id=%{public}s name=%{public}s bus=%{public}d address=%{public}d',
          makeDeviceId(device), device.name, device.busNum, device.devAddress);
        continue;
      }
      const id: string = makeDeviceId(device);
      if (this.handles.has(id)) continue;
      if (this.serialProbed.has(id)) continue;
      if (device.serial !== undefined && device.serial.length > 0) {
        this.serialCache.set(id, device.serial);
        this.serialProbed.add(id);
        this.querySpeed(device);
        continue;
      }
      this.serialProbed.add(id);
      const serial: string = await this.readSerialNumber(device);
      if (serial.length > 0) this.serialCache.set(id, serial);
      this.querySpeed(device);
    }
  }

  async openForImport(deviceId: string, forceClaim: boolean = false): Promise<UsbDeviceHandle> {
    if (!this.sharedIds.has(deviceId)) {
      throw new UsbBackendError('Device is not shared', -19);
    }
    if (this.closingIds.has(deviceId)) {
      throw new UsbBackendError('Previous USB transfer is still draining; this device cannot be reused yet', -16);
    }
    const device: usbManager.USBDevice | undefined = usbManager.getDevices().find(
      (item: usbManager.USBDevice): boolean => makeDeviceId(item) === deviceId
    );
    if (device === undefined) {
      throw new UsbBackendError('USB device disconnected', -19);
    }
    if (!usbManager.hasRight(device.name)) {
      this.closeDevice(deviceId);
      throw new UsbBackendError('USB access permission is required', -13);
    }
    const retainedHandle: UsbDeviceHandle | undefined = this.handles.get(deviceId);
    if (retainedHandle !== undefined) {
      return retainedHandle;
    }
    const pipe: usbManager.USBDevicePipe = usbManager.connectDevice(device);
    if (pipe === undefined) {
      throw new UsbBackendError('Could not open USB device pipe', -5);
    }
    const handle: UsbDeviceHandle = {
      device, pipe, info: mapDevice(device), claimedInterfaces: [],
      activeConfigurationId: device.configs.length > 0 ? asNumber(device.configs[0].id) : 0,
      activeAlternates: new Map<number, number>()
    };
    handle.info.serialNumber = this.serialCache.get(deviceId) ?? handle.info.serialNumber;
    handle.info.speed = this.queryPipeSpeed(pipe);
    const currentConfig: UsbConfigurationInfo | undefined = handle.info.configurations[0];
    if (currentConfig !== undefined) {
      try {
        // Claim without force: the app never silently steals an interface from another local driver.
        for (let index: number = 0; index < currentConfig.interfaces.length; index++) {
          const targetInfo: UsbInterfaceInfo = currentConfig.interfaces[index];
          if (targetInfo.alternateSetting !== 0 || handle.activeAlternates.has(targetInfo.id)) continue;
          const rawInterface: usbManager.USBInterface | undefined = device.configs[0].interfaces.find(
            (item: usbManager.USBInterface): boolean => item.id === targetInfo.id && item.alternateSetting === targetInfo.alternateSetting
          );
          if (rawInterface === undefined) {
            continue;
          }
          const claimResult: number = usbManager.claimInterface(pipe, rawInterface, forceClaim);
          if (claimResult !== 0) {
            throw new UsbBackendError(`USB interface ${targetInfo.id} is busy (claim ${claimResult})`, -16);
          }
          handle.claimedInterfaces.push(rawInterface);
          handle.activeAlternates.set(rawInterface.id, 0);
        }
      } catch (error) {
        this.releaseHandle(handle);
        if (error instanceof UsbBackendError) throw error;
        if (error instanceof Error) throw new UsbBackendError(error.message, -5);
        throw new UsbBackendError('USB interface claim failed', -5);
      }
    }
    this.handles.set(deviceId, handle);
    return handle;
  }

  getHandle(deviceId: string): UsbDeviceHandle | undefined {
    return this.handles.get(deviceId);
  }

  closeDevice(deviceId: string): void {
    if (this.closingIds.has(deviceId)) return;
    const handle: UsbDeviceHandle | undefined = this.handles.get(deviceId);
    if (handle !== undefined) {
      this.handles.delete(deviceId);
      this.releaseHandle(handle);
    }
  }

  closeAll(): void {
    const ids: Array<string> = Array.from(this.handles.keys());
    ids.forEach((id: string) => this.closeDevice(id));
  }

  clearSharedAndCloseAll(): void {
    this.closeAll();
    this.sharedIds.clear();
  }

  private releaseHandle(handle: UsbDeviceHandle): void {
    for (let index: number = handle.claimedInterfaces.length - 1; index >= 0; index--) {
      try {
        usbManager.releaseInterface(handle.pipe, handle.claimedInterfaces[index]);
      } catch (_error) {
      }
    }
    try {
      usbManager.closePipe(handle.pipe);
    } catch (_error) {
    }
  }

  startTransfer(handle: UsbDeviceHandle, endpointAddress: number, direction: number, data: Uint8Array,
    expectedLength: number, timeout: number, transferFlags: number): UsbTransferOperation {
    const endpoint: UsbEndpointInfo | undefined = this.findEndpoint(handle, endpointAddress, direction);
    if (endpoint === undefined) {
      throw new UsbBackendError(`Endpoint ${endpointAddress} is missing from the active configuration`, -32);
    }
    if (endpoint.type === 1) {
      throw new UsbBackendError('Isochronous endpoints are not supported', -95);
    }
    if ((transferFlags & 0x40) !== 0 && (direction !== 0 || endpoint.type !== 2)) {
      throw new UsbBackendError('URB_ZERO_PACKET is supported only for bulk OUT transfers', -95);
    }
    const baseMaxPacketSize: number = endpoint.maxPacketSize & 0x07ff;
    const needsZeroPacket: boolean = (transferFlags & 0x40) !== 0 &&
      expectedLength > 0 && baseMaxPacketSize > 0 && expectedLength % baseMaxPacketSize === 0;
    let settled: boolean = false;
    let cancelRequested: boolean = false;
    let primaryActualLength: number = 0;
    let transfer: usbManager.UsbDataTransferParams | undefined = undefined;
    const promise: Promise<UsbTransferResult> = new Promise<UsbTransferResult>((resolve, reject) => {
      let submitTransfer: (buffer: Uint8Array, length: number, zeroPacket: boolean) => void;
      submitTransfer = (buffer: Uint8Array, length: number, zeroPacket: boolean): void => {
        const params: usbManager.UsbDataTransferParams = {
          devPipe: handle.pipe,
          // Do not pass Linux URB bits or SDK flags that free caller-owned buffers.
          // URB_ZERO_PACKET is implemented below as a second explicit zero-length transfer.
          flags: 0,
          endpoint: endpoint.address,
          type: endpoint.type,
          timeout,
          length,
          userData: new Uint8Array(0),
          isoPacketCount: 0,
          buffer,
          callback: (error: BusinessError, result: usbManager.SubmitTransferCallback) => {
            if (error !== null && error !== undefined) {
              settled = true;
              reject(new UsbBackendError(`USB transfer failed (${error.code})`, this.mapUsbError(error.code)));
              return;
            }
            if (zeroPacket) {
              settled = true;
              resolve({ data, actualLength: primaryActualLength, status: result.status });
              return;
            }
            primaryActualLength = Math.min(expectedLength, asNumber(result.actualLength));
            if (needsZeroPacket && !cancelRequested) {
              submitTransfer(new Uint8Array(0), 0, true);
              return;
            }
            settled = true;
            resolve({ data: buffer, actualLength: primaryActualLength, status: result.status });
          }
        };
        transfer = params;
        try {
          usbManager.usbSubmitTransfer(params);
        } catch (error) {
          const code: number = businessErrorCode(error as Object);
          settled = true;
          reject(new UsbBackendError(`USB transfer submission failed (${code})`, this.mapUsbError(code)));
        }
      };
      const buffer: Uint8Array = direction === 1 ? new Uint8Array(expectedLength) : data;
      submitTransfer(buffer, expectedLength, false);
    });
    const operation: UsbTransferOperation = {
      promise,
      cancel: (): boolean => {
        if (settled || transfer === undefined) return false;
        cancelRequested = true;
        try {
          usbManager.usbCancelTransfer(transfer);
          return true;
        } catch (_error) {
          return false;
        }
      }
    };
    return operation;
  }

  async controlTransfer(handle: UsbDeviceHandle, setup: Uint8Array, payload: Uint8Array,
    length: number, direction: number, timeout: number): Promise<UsbControlTransferResult> {
    const buffer: Uint8Array = direction === 1 ? new Uint8Array(length) : payload;
    const request: usbManager.USBDeviceRequestParams = {
      bmRequestType: setup[0],
      bRequest: setup[1],
      wValue: setup[2] + setup[3] * 256,
      wIndex: setup[4] + setup[5] * 256,
      wLength: length,
      data: buffer
    };
    try {
      const transferred: number = await usbManager.usbControlTransfer(handle.pipe, request, timeout);
      const result: UsbControlTransferResult = { data: buffer, actualLength: Math.min(length, asNumber(transferred)) };
      return result;
    } catch (error) {
      const code: number = businessErrorCode(error as Object);
      throw new UsbBackendError(`USB control transfer failed (${code})`, this.mapUsbError(code));
    }
  }

  setConfiguration(handle: UsbDeviceHandle, value: number, forceClaim: boolean = false): number {
    const config: UsbConfigurationInfo | undefined = handle.info.configurations.find((item: UsbConfigurationInfo): boolean => item.id === value);
    if (config === undefined) {
      return -22;
    }
    handle.claimedInterfaces.forEach((iface: usbManager.USBInterface) => {
      try { usbManager.releaseInterface(handle.pipe, iface); } catch (_error) { }
    });
    handle.claimedInterfaces = [];
    handle.activeAlternates.clear();
    const result: number = usbManager.setConfiguration(handle.pipe, config.raw);
    if (result !== 0) return this.mapUsbError(result);
    handle.activeConfigurationId = config.id;
    let claimFailed: boolean = false;
    const claimedIds: Set<number> = new Set<number>();
    config.raw.interfaces.forEach((iface: usbManager.USBInterface) => {
      if (claimFailed || iface.alternateSetting !== 0 || claimedIds.has(iface.id)) return;
      const claimResult: number = usbManager.claimInterface(handle.pipe, iface, forceClaim);
      if (claimResult !== 0) {
        claimFailed = true;
        return;
      }
      handle.claimedInterfaces.push(iface);
      handle.activeAlternates.set(iface.id, 0);
      claimedIds.add(iface.id);
    });
    if (claimFailed) {
      handle.claimedInterfaces.forEach((iface: usbManager.USBInterface) => {
        try { usbManager.releaseInterface(handle.pipe, iface); } catch (_error) { }
      });
      handle.claimedInterfaces = [];
      handle.activeAlternates.clear();
      return -16;
    }
    return 0;
  }

  setAlternate(handle: UsbDeviceHandle, interfaceId: number, alternate: number): number {
    const activeConfig: usbManager.USBConfiguration | undefined = handle.device.configs.find(
      (config: usbManager.USBConfiguration): boolean => config.id === handle.activeConfigurationId
    );
    if (activeConfig === undefined) return -22;
    const iface: usbManager.USBInterface | undefined = activeConfig.interfaces.find(
      (item: usbManager.USBInterface): boolean => item.id === interfaceId && item.alternateSetting === alternate
    );
    if (iface === undefined) {
      return -22;
    }
    const result: number = usbManager.setInterface(handle.pipe, iface);
    if (result === 0) {
      handle.claimedInterfaces = handle.claimedInterfaces.filter((item: usbManager.USBInterface): boolean => item.id !== interfaceId);
      handle.claimedInterfaces.push(iface);
      handle.activeAlternates.set(interfaceId, alternate);
    }
    return result === 0 ? 0 : this.mapUsbError(result);
  }

  findEndpoint(handle: UsbDeviceHandle, endpointNumber: number, direction: number): UsbEndpointInfo | undefined {
    let found: UsbEndpointInfo | undefined = undefined;
    const config: UsbConfigurationInfo | undefined = handle.info.configurations.find(
      (item: UsbConfigurationInfo): boolean => item.id === handle.activeConfigurationId
    );
    if (config === undefined) return undefined;
    config.interfaces.forEach((iface: UsbInterfaceInfo) => {
      if (handle.activeAlternates.get(iface.id) !== iface.alternateSetting) return;
      iface.endpoints.forEach((endpoint: UsbEndpointInfo) => {
        if (endpoint.number === endpointNumber && ((endpoint.direction === 128 ? 1 : 0) === direction)) {
          found = endpoint;
        }
      });
    });
    return found;
  }

  private mapUsbError(code: number): number {
    if (code === 14400001 || code === 14400002) return -13;
    if (code === 14400007 || code === 16) return -16;
    if (code === 14400008) return -19;
    if (code === 14400011) return -2;
    if (code === 14400003) return -110;
    return -5;
  }

  private querySpeed(device: usbManager.USBDevice): number {
    const id: string = makeDeviceId(device);
    const cached: number | undefined = this.speedCache.get(id);
    if (cached !== undefined) return cached;
    if (!usbManager.hasRight(device.name)) return 0;
    const existing: UsbDeviceHandle | undefined = this.handles.get(id);
    if (existing !== undefined) {
      const activeSpeed: number = this.queryPipeSpeed(existing.pipe);
      this.speedCache.set(id, activeSpeed);
      return activeSpeed;
    }
    let pipe: usbManager.USBDevicePipe | undefined = undefined;
    try {
      pipe = usbManager.connectDevice(device);
      if (pipe === undefined) {
        this.speedCache.set(id, 0);
        return 0;
      }
      const speed: number = this.queryPipeSpeed(pipe);
      this.speedCache.set(id, speed);
      return speed;
    } catch (_error) {
      this.speedCache.set(id, 0);
      return 0;
    } finally {
      if (pipe !== undefined) {
        try { usbManager.closePipe(pipe); } catch (_error) { }
      }
    }
  }

  private queryPipeSpeed(pipe: usbManager.USBDevicePipe): number {
    try {
      const fd: number = usbManager.getFileDescriptor(pipe);
      if (fd < 0) return 0;
      const speed: number = usbipNative.getUsbSpeed(fd);
      return speed >= 1 && speed <= 6 ? speed : 0;
    } catch (_error) {
      return 0;
    }
  }

  private async readSerialNumber(device: usbManager.USBDevice): Promise<string> {
    if (device.serial !== undefined && device.serial.length > 0) return device.serial;
    let pipe: usbManager.USBDevicePipe | undefined = undefined;
    try {
      pipe = usbManager.connectDevice(device);
      if (pipe === undefined) return '';
      const speed: number = this.queryPipeSpeed(pipe);
      this.speedCache.set(makeDeviceId(device), speed);
      const descriptorRequest: usbManager.USBDeviceRequestParams = {
        bmRequestType: 0x80, bRequest: 6, wValue: 0x0100, wIndex: 0, wLength: 18,
        data: new Uint8Array(18)
      };
      const descriptorLength: number = await usbManager.usbControlTransfer(pipe, descriptorRequest, 1000);
      if (descriptorLength < 18 || descriptorRequest.data[16] === 0) return '';
      const serialIndex: number = descriptorRequest.data[16];
      const languageRequest: usbManager.USBDeviceRequestParams = {
        bmRequestType: 0x80, bRequest: 6, wValue: 0x0300, wIndex: 0, wLength: 255,
        data: new Uint8Array(255)
      };
      const languageLength: number = await usbManager.usbControlTransfer(pipe, languageRequest, 1000);
      if (languageLength < 4 || languageRequest.data[1] !== 3) return '';
      const languageId: number = languageRequest.data[2] + languageRequest.data[3] * 256;
      const stringRequest: usbManager.USBDeviceRequestParams = {
        bmRequestType: 0x80, bRequest: 6, wValue: 0x0300 | serialIndex, wIndex: languageId, wLength: 255,
        data: new Uint8Array(255)
      };
      const stringLength: number = await usbManager.usbControlTransfer(pipe, stringRequest, 1000);
      if (stringLength < 2 || stringRequest.data[1] !== 3) return '';
      const bytesToDecode: number = Math.min(stringLength, stringRequest.data[0]) & 0xfe;
      let serial: string = '';
      for (let offset: number = 2; offset + 1 < bytesToDecode; offset += 2) {
        const codeUnit: number = stringRequest.data[offset] + stringRequest.data[offset + 1] * 256;
        if (codeUnit === 0) break;
        serial += String.fromCharCode(codeUnit);
      }
      return serial.trim();
    } catch (_error) {
      return '';
    } finally {
      if (pipe !== undefined) {
        try { usbManager.closePipe(pipe); } catch (_error) { }
      }
    }
  }
}
