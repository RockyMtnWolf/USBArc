import { usbManager } from '@kit.BasicServicesKit';
import {
  DdkConfigurationDescriptor,
  DdkDeviceDescriptor,
  DdkDriverHealth,
  DdkReleasedCleanup,
  DdkDriverClient,
  DdkDriverClientError,
  DdkSystemDeviceInfo,
  DdkTransferResult,
  getDdkPhysicalBusAddress,
  mapDdkUsbErrno
} from '../services/DdkDriverClient';
import {
  UsbConfigurationInfo,
  UsbControlTransferResult,
  UsbDeviceInfo,
  UsbDdkDeviceHandle,
  UsbEndpointInfo,
  UsbInterfaceInfo,
  UsbTransferOperation,
  UsbTransferResult
} from './UsbModels';
import { UsbBackendError } from './UsbManagerBackend';
import { readUsbNegotiatedSpeed } from '../services/UsbNegotiatedSpeed';
import {
  mergeUsbDisplayMetadata,
  selectUsbManagerMetadata,
  UsbDisplayMetadata,
  UsbManagerDeviceMetadata
} from './UsbDeviceMetadata';

export function makeDdkUsbIpBusId(ddkDeviceId: string): string {
  if (!/^\d{1,20}$/.test(ddkDeviceId)) {
    throw new DdkDriverClientError('DDK returned an invalid opaque device ID', -22, -22);
  }
  const busId: string = `ddk-${ddkDeviceId}`;
  if (busId.length > 31) throw new DdkDriverClientError('DDK logical bus ID exceeds USB/IP field length', -22, -22);
  return busId;
}

export function decodeDdkUsbString(bytes: Array<number>): string {
  if (bytes.length < 2 || bytes[1] !== 3 || bytes[0] < 2 || bytes[0] > bytes.length || bytes[0] % 2 !== 0) return '';
  let result: string = '';
  for (let index: number = 2; index < bytes[0]; index += 2) {
    const low: number = bytes[index];
    const high: number = bytes[index + 1];
    if (!Number.isInteger(low) || !Number.isInteger(high) || low < 0 || low > 255 || high < 0 || high > 255) return '';
    result += String.fromCharCode(low | (high << 8));
  }
  return result.replace(/[\u0000-\u001f\u007f]/g, '').trim();
}

/** DeviceManager description may be a hardware path rather than a product name. */
export function ddkDisplayName(product: string, description: string, vendorId: number, productId: number): string {
  if (product.trim().length > 0) return product.trim();
  const readable: string = description.trim();
  if (readable.length > 0 && !/^USB[&\\/]/i.test(readable) && !/VID_[0-9a-f]+/i.test(readable)) return readable;
  return `USB ${vendorId.toString(16).padStart(4, '0').toUpperCase()}:${productId.toString(16).padStart(4, '0').toUpperCase()}`;
}

/** A deterministic server-side bus number, explicitly not a physical USB bus number. */
export function makeDdkLogicalBusNumber(ddkDeviceId: string): number {
  let hash: number = 2166136261;
  for (let index: number = 0; index < ddkDeviceId.length; index++) {
    hash = Math.imul(hash ^ ddkDeviceId.charCodeAt(index), 16777619) >>> 0;
  }
  return 0xd000 | (hash & 0x0fff);
}

export function selectUniqueDdkMatch(systemDevice: DdkSystemDeviceInfo,
  descriptors: Array<DdkDeviceDescriptor>): DdkDeviceDescriptor {
  const physicalId: string = systemDevice.deviceId.toString();
  const exact: Array<DdkDeviceDescriptor> = descriptors.filter((item: DdkDeviceDescriptor): boolean =>
    item.id === physicalId);
  if (exact.length === 1) {
    if (exact[0].vendorId === systemDevice.vendorId && exact[0].productId === systemDevice.productId) return exact[0];
    throw new DdkDriverClientError('DDK physical device ID does not match USBManager VID/PID', -19, -19);
  }
  const matches: Array<DdkDeviceDescriptor> = descriptors.filter((item: DdkDeviceDescriptor): boolean =>
    item.vendorId === systemDevice.vendorId && item.productId === systemDevice.productId);
  if (matches.length !== 1) {
    const reason: string = matches.length === 0 ? 'No DDK device matches the selected system USB device' :
      'Multiple DDK IDs have the same VID/PID; physical-device identity is ambiguous';
    throw new DdkDriverClientError(reason, -19, -19);
  }
  return matches[0];
}

function descriptorByte(bytes: Array<number>, index: number): number {
  const value: number | undefined = bytes[index];
  if (value === undefined || !Number.isInteger(value) || value < 0 || value > 255) {
    throw new DdkDriverClientError('DDK configuration descriptor has an invalid byte layout', -22, -22);
  }
  return value;
}

/** Parses the packed descriptors returned by OH_Usb_GetConfigDescriptor without manager casts. */
export function parseDdkConfigurationDescriptor(raw: DdkConfigurationDescriptor,
  configurationIndex: number): UsbConfigurationInfo {
  const bytes: Array<number> = raw.bytes;
  if (!Number.isInteger(configurationIndex) || configurationIndex < 0 || bytes.length < 9 ||
    descriptorByte(bytes, 0) < 9 || descriptorByte(bytes, 1) !== 2) {
    throw new DdkDriverClientError('DDK returned a malformed configuration descriptor', -22, -22);
  }
  const declaredLength: number = descriptorByte(bytes, 2) | (descriptorByte(bytes, 3) << 8);
  if (declaredLength < 9 || declaredLength > bytes.length) {
    throw new DdkDriverClientError('DDK configuration descriptor length is inconsistent', -22, -22);
  }
  if (raw.configurationValue !== descriptorByte(bytes, 5)) {
    throw new DdkDriverClientError('DDK configuration value does not match its descriptor bytes', -22, -22);
  }
  const interfaces: Array<UsbInterfaceInfo> = [];
  const settingIndexes: Map<number, number> = new Map<number, number>();
  let currentInterface: UsbInterfaceInfo | undefined = undefined;
  let offset: number = 0;
  while (offset < declaredLength) {
    if (offset + 2 > declaredLength) throw new DdkDriverClientError('Truncated USB descriptor header', -22, -22);
    const length: number = descriptorByte(bytes, offset);
    const type: number = descriptorByte(bytes, offset + 1);
    if (length < 2 || offset + length > declaredLength) {
      throw new DdkDriverClientError('USB descriptor length exceeds its configuration buffer', -22, -22);
    }
    if (type === 4) {
      if (length < 9) throw new DdkDriverClientError('USB interface descriptor is truncated', -22, -22);
      const id: number = descriptorByte(bytes, offset + 2);
      const settingIndex: number = settingIndexes.get(id) ?? 0;
      settingIndexes.set(id, settingIndex + 1);
      currentInterface = {
        id,
        alternateSetting: descriptorByte(bytes, offset + 3),
        clazz: descriptorByte(bytes, offset + 5),
        subClass: descriptorByte(bytes, offset + 6),
        protocol: descriptorByte(bytes, offset + 7),
        settingIndex,
        endpoints: []
      };
      interfaces.push(currentInterface);
    } else if (type === 5 && currentInterface !== undefined) {
      if (length < 7) throw new DdkDriverClientError('USB endpoint descriptor is truncated', -22, -22);
      const address: number = descriptorByte(bytes, offset + 2);
      const attributes: number = descriptorByte(bytes, offset + 3);
      const endpoint: UsbEndpointInfo = {
        address,
        attributes,
        maxPacketSize: descriptorByte(bytes, offset + 4) | (descriptorByte(bytes, offset + 5) << 8),
        interval: descriptorByte(bytes, offset + 6),
        direction: address & 0x80,
        number: address & 0x0f,
        type: attributes & 0x03,
        interfaceId: currentInterface.id
      };
      currentInterface.endpoints.push(endpoint);
    }
    offset += length;
  }
  return {
    id: descriptorByte(bytes, 5),
    index: configurationIndex,
    attributes: descriptorByte(bytes, 7),
    maxPower: descriptorByte(bytes, 8),
    interfaces
  };
}

/** Returns configurations with the system-reported active bConfigurationValue first. */
export function activeConfigurationFirst(configurations: Array<UsbConfigurationInfo>, activeValue: number): Array<UsbConfigurationInfo> {
  const activeIndex: number = configurations.findIndex(
    (item: UsbConfigurationInfo): boolean => item.id === activeValue);
  if (activeIndex < 0) {
    throw new DdkDriverClientError('Active USB configuration is absent from the DDK descriptors', -95, -95);
  }
  const ordered: Array<UsbConfigurationInfo> = configurations.slice();
  if (activeIndex > 0) {
    const active: UsbConfigurationInfo = ordered[activeIndex];
    ordered.splice(activeIndex, 1);
    ordered.unshift(active);
  }
  return ordered;
}

/** Maps USB/IP's endpoint number + direction to the full USB descriptor address (including bit 7). */
export function findDdkEndpoint(configurations: Array<UsbConfigurationInfo>, activeConfigurationId: number,
  activeAlternates: Map<number, number>, endpointNumber: number, direction: number): UsbEndpointInfo | undefined {
  const config: UsbConfigurationInfo | undefined = configurations.find(
    (item: UsbConfigurationInfo): boolean => item.id === activeConfigurationId);
  if (config === undefined) return undefined;
  for (let index: number = 0; index < config.interfaces.length; index++) {
    const iface: UsbInterfaceInfo = config.interfaces[index];
    if (activeAlternates.get(iface.id) !== iface.alternateSetting) continue;
    const endpoint: UsbEndpointInfo | undefined = iface.endpoints.find((item: UsbEndpointInfo): boolean =>
      item.number === endpointNumber && (item.direction === 0x80 ? 1 : 0) === direction);
    if (endpoint !== undefined) return endpoint;
  }
  return undefined;
}

function bcdVersion(value: number): string {
  const high: number = (value >>> 8) & 0xff;
  const low: number = value & 0xff;
  const major: number = ((high >>> 4) & 0xf) * 10 + (high & 0xf);
  const minor: number = ((low >>> 4) & 0xf) * 10 + (low & 0xf);
  return `${major}.${minor}`;
}

function readUsbManagerMetadata(): Array<UsbManagerDeviceMetadata> {
  try {
    return usbManager.getDevices().map((device: usbManager.USBDevice): UsbManagerDeviceMetadata => ({
      vendorId: device.vendorId,
      productId: device.productId,
      busNum: device.busNum,
      devAddress: device.devAddress,
      manufacturerName: device.manufacturerName,
      productName: device.productName,
      serialNumber: device.serial ?? ''
    }));
  } catch (_error) {
    // Metadata is optional; DDK enumeration and connection remain independent.
    return [];
  }
}

function makeSystemRow(system: DdkSystemDeviceInfo, managerDevices: ReadonlyArray<UsbManagerDeviceMetadata>): UsbDeviceInfo {
  const id: string = `ddk-system-${system.deviceId}`;
  const managerMetadata: UsbManagerDeviceMetadata | undefined = selectUsbManagerMetadata(
    system.vendorId, system.productId, system.description, managerDevices,
    getDdkPhysicalBusAddress(system.deviceId));
  const display: UsbDisplayMetadata = mergeUsbDisplayMetadata(managerMetadata, {
    manufacturer: '', product: '', serialNumber: ''
  });
  return {
    id,
    name: ddkDisplayName(display.product, system.description, system.vendorId, system.productId),
    path: '',
    busId: `ddk-system-${system.deviceId}`,
    busNum: 0,
    devAddress: 0,
    vendorId: system.vendorId,
    productId: system.productId,
    speed: 0,
    manufacturer: display.manufacturer,
    product: display.product,
    serialNumber: display.serialNumber,
    version: '',
    deviceClass: 0,
    deviceSubClass: 0,
    deviceProtocol: 0,
    configurations: [],
    backendDeviceId: system.deviceId,
    authorized: false,
    occupied: false,
    shared: false,
    imported: false,
    closing: false,
    available: true
  };
}

function applyDisplayMetadata(
  row: UsbDeviceInfo,
  system: DdkSystemDeviceInfo,
  managerDevices: ReadonlyArray<UsbManagerDeviceMetadata>
): void {
  const managerMetadata: UsbManagerDeviceMetadata | undefined = selectUsbManagerMetadata(
    system.vendorId, system.productId, system.description, managerDevices);
  const display: UsbDisplayMetadata = mergeUsbDisplayMetadata(managerMetadata, {
    manufacturer: row.manufacturer, product: row.product, serialNumber: row.serialNumber
  });
  row.manufacturer = display.manufacturer;
  row.product = display.product;
  row.serialNumber = display.serialNumber;
  row.name = ddkDisplayName(display.product, system.description, system.vendorId, system.productId);
}

export class UsbDdkBackend {
  private readonly client: DdkDriverClient;
  private selected: Map<string, UsbDeviceInfo> = new Map<string, UsbDeviceInfo>();
  private handles: Map<string, UsbDdkDeviceHandle> = new Map<string, UsbDdkDeviceHandle>();
  private selectedSystemDevices: Map<number, string> = new Map<number, string>();
  private sharedIds: Set<string> = new Set<string>();
  private closingIds: Set<string> = new Set<string>();
  private unavailableIds: Set<string> = new Set<string>();
  private removedIds: Array<string> = [];

  constructor(client: DdkDriverClient = new DdkDriverClient()) {
    this.client = client;
    this.client.subscribeDisconnect((systemDeviceId: number): void => {
      const id: string = this.selectedSystemDevices.get(systemDeviceId) ?? '';
      if (id.length === 0) return;
      this.removedIds.push(id);
      this.handles.delete(id);
      this.selected.delete(id);
      this.sharedIds.delete(id);
      this.closingIds.delete(id);
      this.selectedSystemDevices.delete(systemDeviceId);
    });
  }

  async refreshMetadata(): Promise<void> {
    const systems: Array<DdkSystemDeviceInfo> = this.client.listSystemDevices();
    const present: Set<number> = new Set<number>(systems.map((item: DdkSystemDeviceInfo): number => item.deviceId));
    const stale: Array<number> = [];
    this.selectedSystemDevices.forEach((_id: string, systemId: number): void => {
      if (!present.has(systemId)) stale.push(systemId);
    });
    for (let index: number = 0; index < stale.length; index++) {
      const systemId: number = stale[index];
      const id: string = this.selectedSystemDevices.get(systemId) ?? '';
      if (id.length > 0) {
        this.removedIds.push(id);
        await this.closeDevice(id);
        this.selected.delete(id);
        this.sharedIds.delete(id);
        this.closingIds.delete(id);
      }
      this.selectedSystemDevices.delete(systemId);
      await this.client.unbind(systemId);
    }

    const selectedSystemIds: Array<number> = Array.from(this.selectedSystemDevices.keys());
    for (let index: number = 0; index < selectedSystemIds.length; index++) {
      const systemId: number = selectedSystemIds[index];
      const id: string = this.selectedSystemDevices.get(systemId) ?? '';
      if (id.length === 0) continue;
      let health: DdkDriverHealth = 'unavailable';
      try {
        health = await this.client.checkHealth(systemId);
      } catch (_error) {
        this.unavailableIds.add(id);
        continue;
      }
      if (health === 'healthy') {
        this.unavailableIds.delete(id);
        continue;
      }
      if (health === 'released') {
        try { await this.cleanupReleasedDevice(systemId, id); }
        catch (_error) { this.unavailableIds.add(id); }
      } else {
        this.unavailableIds.add(id);
      }
    }
  }

  listDevices(): Array<UsbDeviceInfo> {
    const systems: Array<DdkSystemDeviceInfo> = this.client.listSystemDevices();
    const managerDevices: Array<UsbManagerDeviceMetadata> = readUsbManagerMetadata();
    return systems.map((system: DdkSystemDeviceInfo): UsbDeviceInfo => {
      const id: string = `ddk-system-${system.deviceId}`;
      const selected: UsbDeviceInfo | undefined = this.selected.get(id);
      const row: UsbDeviceInfo = selected === undefined ? makeSystemRow(system, managerDevices) : this.copyInfo(selected);
      applyDisplayMetadata(row, system, managerDevices);
      if (selected !== undefined) this.selected.set(id, this.copyInfo(row));
      const handle: UsbDdkDeviceHandle | undefined = this.handles.get(id);
      const unavailable: boolean = this.unavailableIds.has(id);
      row.authorized = selected !== undefined && !unavailable;
      row.occupied = handle !== undefined && handle.claimedInterfaces.length > 0;
      row.shared = this.sharedIds.has(id);
      row.closing = this.closingIds.has(id) || unavailable;
      row.available = !row.closing;
      return row;
    });
  }

  async requestPermission(deviceId: string): Promise<boolean> {
    const systemDeviceId: number = this.systemDeviceIdFromPublicId(deviceId);
    await this.selectSystemDevice(systemDeviceId);
    return true;
  }

  private async selectSystemDevice(systemDeviceId: number): Promise<UsbDeviceInfo> {
    const system: DdkSystemDeviceInfo | undefined = this.client.listSystemDevices().find(
      (item: DdkSystemDeviceInfo): boolean => item.deviceId === systemDeviceId);
    if (system === undefined) throw new DdkDriverClientError('Selected USB device is no longer present', -19, -19);
    // Read only the manager's descriptor snapshot before binding; do not request rights or open a pipe here.
    const managerMetadata: UsbManagerDeviceMetadata | undefined = selectUsbManagerMetadata(
      system.vendorId, system.productId, system.description, readUsbManagerMetadata(),
      getDdkPhysicalBusAddress(system.deviceId));
    const publicId: string = `ddk-system-${systemDeviceId}`;
    const previouslySelected: UsbDeviceInfo | undefined = this.selected.get(publicId);
    if (previouslySelected !== undefined && previouslySelected.authorized &&
      previouslySelected.backendDeviceId === systemDeviceId && previouslySelected.opaqueDeviceId !== undefined) {
      try {
        const health: DdkDriverHealth = await this.client.checkHealth(systemDeviceId);
        if (health === 'healthy') {
          this.unavailableIds.delete(publicId);
          applyDisplayMetadata(previouslySelected, system, managerMetadata === undefined ? [] : [managerMetadata]);
          if (previouslySelected.speed === 0 && !this.handles.has(publicId)) {
            previouslySelected.speed = await readUsbNegotiatedSpeed(system.vendorId, system.productId, true,
              getDdkPhysicalBusAddress(system.deviceId));
          }
          // Never rebind a live selection: it may have interfaces claimed by an active import.
          return this.copyInfo(previouslySelected);
        }
        if (health === 'released') await this.cleanupReleasedDevice(systemDeviceId, publicId);
        else this.unavailableIds.add(publicId);
      } catch (error) {
        this.unavailableIds.add(publicId);
        if (error instanceof DdkDriverClientError) throw error;
        throw new DdkDriverClientError('DDK driver health could not be confirmed', -5, -5);
      }
      throw new DdkDriverClientError('DDK driver stopped or is unavailable; retry the connection request', -16, -16);
    }
    try {
      await this.client.bind(systemDeviceId);
    } catch (error) {
      if (error instanceof Error) throw error;
      throw new DdkDriverClientError('DDK driver binding failed', -5, -5);
    }
    try {
      const opaqueIds: Array<string> = await this.client.getDriverDeviceIds(systemDeviceId);
      const descriptors: Array<DdkDeviceDescriptor> = [];
      for (let index: number = 0; index < opaqueIds.length; index++) {
        descriptors.push(await this.client.getDeviceDescriptor(systemDeviceId, opaqueIds[index]));
      }
      const descriptor: DdkDeviceDescriptor = selectUniqueDdkMatch(system, descriptors);
      const busId: string = makeDdkUsbIpBusId(descriptor.id);
      const logicalBusNumber: number = makeDdkLogicalBusNumber(descriptor.id);
      const activeConfigurationValue: number = await this.client.getActiveConfiguration(systemDeviceId, descriptor.id);
      const collision: boolean = Array.from(this.selected.values()).some(
        (item: UsbDeviceInfo): boolean => item.id !== `ddk-system-${systemDeviceId}` && item.busNum === logicalBusNumber);
      if (collision) throw new DdkDriverClientError('DDK logical bus number collision; refusing ambiguous USB/IP ID', -22, -22);
      const configurations: Array<UsbConfigurationInfo> = [];
      for (let index: number = 0; index < descriptor.configurationCount; index++) {
        const raw: DdkConfigurationDescriptor = await this.client.getConfigurationDescriptor(
          systemDeviceId, descriptor.id, index);
        configurations.push(parseDdkConfigurationDescriptor(raw, index));
      }
      const orderedConfigurations: Array<UsbConfigurationInfo> =
        activeConfigurationFirst(configurations, activeConfigurationValue);
      const strings: Array<string> = await this.readDeviceStrings(systemDeviceId, descriptor);
      const display = mergeUsbDisplayMetadata(managerMetadata, {
        manufacturer: strings[0], product: strings[1], serialNumber: strings[2]
      });
      const info: UsbDeviceInfo = {
        id: `ddk-system-${systemDeviceId}`,
        name: ddkDisplayName(display.product, system.description, descriptor.vendorId, descriptor.productId),
        path: `ddk/${descriptor.id}`,
        busId,
        busNum: logicalBusNumber,
        devAddress: 1,
        vendorId: descriptor.vendorId,
        productId: descriptor.productId,
        speed: await readUsbNegotiatedSpeed(descriptor.vendorId, descriptor.productId, true,
          getDdkPhysicalBusAddress(system.deviceId)),
        manufacturer: display.manufacturer,
        product: display.product,
        serialNumber: display.serialNumber,
        version: bcdVersion(descriptor.bcdDevice),
        deviceClass: descriptor.deviceClass,
        deviceSubClass: descriptor.deviceSubClass,
        deviceProtocol: descriptor.deviceProtocol,
        configurations: orderedConfigurations,
        backendDeviceId: systemDeviceId,
        opaqueDeviceId: descriptor.id,
        authorized: true,
        occupied: false,
        shared: this.sharedIds.has(`ddk-system-${systemDeviceId}`),
        imported: false,
        closing: false,
        available: true
      };
      this.selected.set(info.id, info);
      this.selectedSystemDevices.set(systemDeviceId, info.id);
      return info;
    } catch (error) {
      await this.client.unbind(systemDeviceId);
      if (error instanceof DdkDriverClientError) throw error;
      throw new DdkDriverClientError('Could not resolve selected DDK device identity', -5, -5);
    }
  }

  private async readDeviceStrings(systemDeviceId: number, descriptor: DdkDeviceDescriptor): Promise<Array<string>> {
    const result: Array<string> = ['', '', ''];
    const indexes: Array<number> = descriptor.bytes.slice(14, 17);
    if (indexes.length !== 3 || indexes.every((index: number): boolean => index === 0)) return result;
    let language: number = 0;
    try {
      const languages: DdkTransferResult = await this.client.controlTransfer(systemDeviceId, descriptor.id,
        [0x80, 6, 0, 3, 0, 0, 255, 0], new Array<number>(255).fill(0), 1000);
      const bytes: Array<number> = languages.data;
      if (bytes.length < 4 || bytes[1] !== 3 || bytes[0] < 4 || bytes[0] > bytes.length || bytes[0] % 2 !== 0) return result;
      language = bytes[2] | (bytes[3] << 8);
      for (let offset: number = 2; offset < bytes[0]; offset += 2) {
        const candidate: number = bytes[offset] | (bytes[offset + 1] << 8);
        if (candidate === 0x0409) language = candidate;
      }
    } catch (_error) {
      return result;
    }
    const cached: Map<number, string> = new Map<number, string>();
    for (let slot: number = 0; slot < indexes.length; slot++) {
      const index: number = indexes[slot];
      if (!Number.isInteger(index) || index < 1 || index > 255) continue;
      const previous: string | undefined = cached.get(index);
      if (previous !== undefined) { result[slot] = previous; continue; }
      try {
        const response: DdkTransferResult = await this.client.controlTransfer(systemDeviceId, descriptor.id,
          [0x80, 6, index, 3, language & 255, language >> 8, 255, 0], new Array<number>(255).fill(0), 1000);
        result[slot] = decodeDdkUsbString(response.data);
        cached.set(index, result[slot]);
      } catch (_error) {
        // Optional strings do not invalidate a successful driver bind and descriptor query.
      }
    }
    return result;
  }

  addShared(deviceId: string): void {
    const info: UsbDeviceInfo | undefined = this.selected.get(deviceId);
    if (info === undefined || !info.authorized || info.opaqueDeviceId === undefined) {
      throw new UsbBackendError('Bind and initialize the DDK driver for this device before sharing', -13);
    }
    if (this.unavailableIds.has(deviceId)) throw new UsbBackendError('DDK driver health is unavailable', -19);
    this.sharedIds.add(deviceId);
  }

  removeShared(deviceId: string): void {
    this.sharedIds.delete(deviceId);
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

  async pruneMissingDevices(): Promise<Array<string>> {
    const removed: Array<string> = this.removedIds.slice();
    this.removedIds = [];
    return removed;
  }

  async openForImport(deviceId: string, forceClaim: boolean = false): Promise<UsbDdkDeviceHandle> {
    if (!this.sharedIds.has(deviceId)) throw new UsbBackendError('DDK device is not selected for sharing', -19);
    if (this.closingIds.has(deviceId)) throw new UsbBackendError('Previous DDK transfer is still draining', -16);
    if (this.unavailableIds.has(deviceId)) throw new UsbBackendError('DDK driver health is unavailable', -19);
    // DDK claim behavior is fixed by the platform service. The USBManager force option does not apply here.
    void forceClaim;
    const retained: UsbDdkDeviceHandle | undefined = this.handles.get(deviceId);
    if (retained !== undefined) return retained;
    const info: UsbDeviceInfo | undefined = this.selected.get(deviceId);
    if (info === undefined || info.backendDeviceId === undefined || info.opaqueDeviceId === undefined) {
      throw new UsbBackendError('DDK device is not bound and initialized', -13);
    }
    if (info.speed === 0) {
      const physicalIdentity = info.backendDeviceId === undefined ? undefined :
        getDdkPhysicalBusAddress(info.backendDeviceId);
      info.speed = await readUsbNegotiatedSpeed(info.vendorId, info.productId, true, physicalIdentity);
    }
    if (info.speed === 0) {
      throw new UsbBackendError('无法读取实际 USB 速率；请完成系统 USB 授权后重新共享。设备传输仍使用 DDK。', -95);
    }
    const configuration: UsbConfigurationInfo | undefined = info.configurations[0];
    if (configuration === undefined || configuration.interfaces.length === 0) {
      throw new UsbBackendError('DDK device has no supported configuration interfaces', -95);
    }
    const live: DdkDeviceDescriptor = await this.client.getDeviceDescriptor(info.backendDeviceId, info.opaqueDeviceId);
    if (live.vendorId !== info.vendorId || live.productId !== info.productId || live.id !== info.opaqueDeviceId) {
      throw new UsbBackendError('DDK device identity changed after selection', -19);
    }
    const handle: UsbDdkDeviceHandle = {
      backendMode: 'usbDdk',
      info,
      activeConfigurationId: configuration.id,
      activeAlternates: new Map<number, number>(),
      claimedInterfaces: [],
      systemDeviceId: info.backendDeviceId,
      opaqueDeviceId: info.opaqueDeviceId,
      claimTokens: new Map<number, string>()
    };
    this.handles.set(deviceId, handle);
    try {
      const interfaceIds: Set<number> = new Set<number>();
      configuration.interfaces.forEach((iface: UsbInterfaceInfo): void => { interfaceIds.add(iface.id); });
      for (const interfaceNumber of interfaceIds) {
        const defaultAlt: UsbInterfaceInfo | undefined = configuration.interfaces.find(
          (iface: UsbInterfaceInfo): boolean => iface.id === interfaceNumber && iface.alternateSetting === 0);
        if (defaultAlt === undefined) throw new UsbBackendError(`Interface ${interfaceNumber} has no alternate 0`, -95);
        const claim: string = await this.client.claimInterface(handle.systemDeviceId, handle.opaqueDeviceId, interfaceNumber);
        handle.claimedInterfaces.push(interfaceNumber);
        handle.claimTokens.set(interfaceNumber, claim);
        if ((defaultAlt.settingIndex ?? 0) !== 0) {
          await this.client.selectInterfaceSetting(handle.systemDeviceId, claim, defaultAlt.settingIndex ?? 0);
        }
        handle.activeAlternates.set(interfaceNumber, 0);
      }
    } catch (error) {
      try {
        await this.releaseHandle(handle);
        this.handles.delete(deviceId);
      } catch (releaseError) {
        this.closingIds.add(deviceId);
        const detail: string = releaseError instanceof Error ? releaseError.message : 'unknown release error';
        throw new UsbBackendError(`DDK claim failed and cleanup is incomplete: ${detail}`, -16);
      }
      if (error instanceof UsbBackendError) throw error;
      if (error instanceof DdkDriverClientError) throw new UsbBackendError(error.message, error.usbErrno);
      throw new UsbBackendError('DDK interface claim failed', -5);
    }
    this.handles.set(deviceId, handle);
    return handle;
  }

  getHandle(deviceId: string): UsbDdkDeviceHandle | undefined {
    return this.handles.get(deviceId);
  }

  async closeDevice(deviceId: string): Promise<void> {
    const handle: UsbDdkDeviceHandle | undefined = this.handles.get(deviceId);
    if (handle === undefined) return;
    try {
      await this.releaseHandle(handle);
    } catch (error) {
      this.closingIds.add(deviceId);
      if (error instanceof UsbBackendError) throw error;
      throw new UsbBackendError('DDK interface release failed; device remains occupied', -16);
    }
    this.handles.delete(deviceId);
    this.closingIds.delete(deviceId);
    this.unavailableIds.delete(deviceId);
  }

  async closeAll(): Promise<void> {
    const ids: Array<string> = Array.from(this.handles.keys());
    let firstError: Error | undefined = undefined;
    for (let index: number = 0; index < ids.length; index++) {
      try { await this.closeDevice(ids[index]); }
      catch (error) {
        if (firstError === undefined) {
          firstError = error instanceof Error ? error : new UsbBackendError('DDK handle release failed', -16);
        }
      }
    }
    if (firstError !== undefined) throw firstError;
  }

  async clearSharedAndCloseAll(): Promise<void> {
    await this.closeAll();
    await this.client.unbindAll();
    this.sharedIds.clear();
    this.selected.clear();
    this.selectedSystemDevices.clear();
    this.unavailableIds.clear();
  }

  setConfiguration(handle: UsbDdkDeviceHandle, value: number): number {
    return handle.info.configurations.some((item: UsbConfigurationInfo): boolean =>
      item.id === value) && handle.activeConfigurationId === value ? 0 : -95;
  }

  async setAlternate(handle: UsbDdkDeviceHandle, interfaceNumber: number, alternateSetting: number): Promise<number> {
    const config: UsbConfigurationInfo | undefined = handle.info.configurations.find(
      (item: UsbConfigurationInfo): boolean => item.id === handle.activeConfigurationId);
    const alternate: UsbInterfaceInfo | undefined = config?.interfaces.find(
      (item: UsbInterfaceInfo): boolean => item.id === interfaceNumber && item.alternateSetting === alternateSetting);
    const claim: string | undefined = handle.claimTokens.get(interfaceNumber);
    if (alternate === undefined || claim === undefined) return -22;
    try {
      await this.client.selectInterfaceSetting(handle.systemDeviceId, claim, alternate.settingIndex ?? 0);
      handle.activeAlternates.set(interfaceNumber, alternateSetting);
      return 0;
    } catch (error) {
      return error instanceof DdkDriverClientError ? error.usbErrno : -5;
    }
  }

  async controlTransfer(handle: UsbDdkDeviceHandle, setup: Uint8Array, payload: Uint8Array,
    length: number, _direction: number, timeout: number): Promise<UsbControlTransferResult> {
    const claim: string | undefined = handle.claimTokens.values().next().value;
    if (claim === undefined) throw new UsbBackendError('DDK control transfer requires a claimed interface', -19);
    let result: DdkTransferResult;
    try {
      const input: boolean = (setup[0] & 0x80) !== 0;
      const transferData: Uint8Array = input ? new Uint8Array(length) : payload;
      result = await this.client.controlTransfer(handle.systemDeviceId, handle.opaqueDeviceId,
        Array.from(setup), Array.from(transferData), timeout, claim);
    } catch (error) {
      if (error instanceof DdkDriverClientError) throw new UsbBackendError(error.message, error.usbErrno);
      throw new UsbBackendError('DDK control transfer failed', -5);
    }
    return { data: new Uint8Array(result.data), actualLength: result.actualLength };
  }

  startTransfer(handle: UsbDdkDeviceHandle, endpointNumber: number, direction: number, data: Uint8Array,
    expectedLength: number, timeout: number, transferFlags: number): UsbTransferOperation {
    if ((transferFlags & 0x40) !== 0) {
      throw new UsbBackendError('DDK does not implement URB_ZERO_PACKET semantics', -95);
    }
    const endpoint: UsbEndpointInfo | undefined = findDdkEndpoint(handle.info.configurations,
      handle.activeConfigurationId, handle.activeAlternates, endpointNumber, direction);
    if (endpoint === undefined) throw new UsbBackendError(`DDK endpoint ${endpointNumber} direction ${direction} is unavailable`, -32);
    if (endpoint.type === 1) throw new UsbBackendError('DDK isochronous transfers are not supported', -95);
    if (expectedLength > 1048576) throw new UsbBackendError('DDK pipe transfers are limited to 1 MiB', -90);
    const claim: string | undefined = handle.claimTokens.get(endpoint.interfaceId);
    if (claim === undefined) throw new UsbBackendError('DDK endpoint interface is not claimed', -19);
    const transferData: Uint8Array = direction === 1 ? new Uint8Array(expectedLength) : data;
    const promise: Promise<UsbTransferResult> = this.client.pipeTransfer(handle.systemDeviceId, claim,
      endpoint.address, Array.from(transferData), timeout).then((result: DdkTransferResult): UsbTransferResult => {
      if (result.status !== 0) throw new UsbBackendError('DDK pipe transfer failed', mapDdkUsbErrno(result.status));
      return { data: new Uint8Array(result.data), actualLength: result.actualLength, status: result.status };
    }, (error: Object): Promise<UsbTransferResult> => {
      if (error instanceof DdkDriverClientError) throw new UsbBackendError(error.message, error.usbErrno);
      throw new UsbBackendError('DDK pipe transfer failed', -5);
    });
    return { promise, cancel: (): boolean => false };
  }

  private async releaseHandle(handle: UsbDdkDeviceHandle): Promise<void> {
    const claims: Array<[number, string]> = Array.from(handle.claimTokens.entries());
    for (let index: number = claims.length - 1; index >= 0; index--) {
      await this.client.releaseInterface(handle.systemDeviceId, claims[index][1]);
      handle.claimTokens.delete(claims[index][0]);
      handle.claimedInterfaces = handle.claimedInterfaces.filter((id: number): boolean => id !== claims[index][0]);
      handle.activeAlternates.delete(claims[index][0]);
    }
  }

  private async cleanupReleasedDevice(systemDeviceId: number, deviceId: string): Promise<void> {
    const cleanup: DdkReleasedCleanup = await this.client.cleanupReleasedBinding(systemDeviceId);
    if (cleanup === 'not-released') {
      this.unavailableIds.add(deviceId);
      return;
    }
    const handle: UsbDdkDeviceHandle | undefined = this.handles.get(deviceId);
    if (handle !== undefined) {
      // A fresh health reply confirmed that the extension released every native claim.
      handle.claimTokens.clear();
      handle.claimedInterfaces = [];
      handle.activeAlternates.clear();
    }
    if (cleanup === 'released-still-bound') {
      this.unavailableIds.add(deviceId);
      return;
    }
    if (handle !== undefined) this.removedIds.push(deviceId);
    this.handles.delete(deviceId);
    this.selected.delete(deviceId);
    this.selectedSystemDevices.delete(systemDeviceId);
    this.closingIds.delete(deviceId);
    this.unavailableIds.delete(deviceId);
  }

  private copyInfo(source: UsbDeviceInfo): UsbDeviceInfo {
    return {
      id: source.id, name: source.name, path: source.path, busId: source.busId, busNum: source.busNum,
      devAddress: source.devAddress, vendorId: source.vendorId, productId: source.productId, speed: source.speed,
      manufacturer: source.manufacturer, product: source.product, serialNumber: source.serialNumber,
      version: source.version, deviceClass: source.deviceClass, deviceSubClass: source.deviceSubClass,
      deviceProtocol: source.deviceProtocol, configurations: source.configurations.slice(),
      backendDeviceId: source.backendDeviceId, opaqueDeviceId: source.opaqueDeviceId,
      authorized: source.authorized, occupied: source.occupied, shared: source.shared, imported: source.imported,
      closing: source.closing, available: source.available
    };
  }

  private systemDeviceIdFromPublicId(deviceId: string): number {
    const prefix: string = 'ddk-system-';
    if (!deviceId.startsWith(prefix)) throw new UsbBackendError('Invalid DDK DeviceManager selection ID', -22);
    const suffix: string = deviceId.substring(prefix.length);
    if (suffix.length === 0 || !/^\d+$/.test(suffix)) {
      throw new UsbBackendError('Invalid DDK DeviceManager selection ID', -22);
    }
    return Number.parseInt(suffix, 10);
  }
}
