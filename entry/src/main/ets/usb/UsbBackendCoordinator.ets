import { UsbControlTransferResult, UsbDeviceHandle, UsbDeviceInfo, UsbTransferOperation } from './UsbModels';
import { UsbBackendError, UsbManagerBackend } from './UsbManagerBackend';
import { UsbDdkBackend } from './UsbDdkBackend';

/** Routes a server operation to exactly one selected backend without adapting DDK handles into manager pipes. */
export class UsbBackendCoordinator {
  private readonly manager: UsbManagerBackend = new UsbManagerBackend();
  private readonly ddk: UsbDdkBackend = new UsbDdkBackend();
  private mode: 'usbManager' | 'usbDdk' = 'usbManager';

  currentMode(): 'usbManager' | 'usbDdk' {
    return this.mode;
  }

  async setMode(mode: 'usbManager' | 'usbDdk'): Promise<void> {
    if (mode === this.mode) return;
    await this.clearSharedAndCloseAll();
    this.mode = mode;
  }

  listDevices(): Array<UsbDeviceInfo> {
    return this.mode === 'usbManager' ? this.manager.listDevices() : this.ddk.listDevices();
  }

  async refreshMetadata(): Promise<void> {
    if (this.mode === 'usbManager') await this.manager.refreshMetadata();
    else await this.ddk.refreshMetadata();
  }

  async pruneMissingDevices(): Promise<Array<string>> {
    if (this.mode === 'usbManager') return this.manager.pruneMissingDevices();
    return await this.ddk.pruneMissingDevices();
  }

  async requestPermission(deviceId: string): Promise<boolean> {
    return this.mode === 'usbManager' ? await this.manager.requestPermission(deviceId) :
      await this.ddk.requestPermission(deviceId);
  }

  addShared(deviceId: string): void {
    if (this.mode === 'usbManager') this.manager.addShared(deviceId);
    else this.ddk.addShared(deviceId);
  }

  async removeShared(deviceId: string): Promise<void> {
    if (this.mode === 'usbManager') this.manager.removeShared(deviceId);
    else this.ddk.removeShared(deviceId);
  }

  isShared(deviceId: string): boolean {
    return this.mode === 'usbManager' ? this.manager.isShared(deviceId) : this.ddk.isShared(deviceId);
  }

  getSharedDeviceIds(): Array<string> {
    return this.mode === 'usbManager' ? this.manager.getSharedDeviceIds() : this.ddk.getSharedDeviceIds();
  }

  markDeviceClosing(deviceId: string): void {
    if (this.mode === 'usbManager') this.manager.markDeviceClosing(deviceId);
    else this.ddk.markDeviceClosing(deviceId);
  }

  clearDeviceClosing(deviceId: string): void {
    if (this.mode === 'usbManager') this.manager.clearDeviceClosing(deviceId);
    else this.ddk.clearDeviceClosing(deviceId);
  }

  hasClosingDevices(): boolean {
    return this.mode === 'usbManager' ? this.manager.hasClosingDevices() : this.ddk.hasClosingDevices();
  }

  isDeviceClosing(deviceId: string): boolean {
    return this.mode === 'usbManager' ? this.manager.isDeviceClosing(deviceId) : this.ddk.isDeviceClosing(deviceId);
  }

  async openForImport(deviceId: string, forceClaim: boolean): Promise<UsbDeviceHandle> {
    return this.mode === 'usbManager' ? await this.manager.openForImport(deviceId, forceClaim) :
      await this.ddk.openForImport(deviceId, forceClaim);
  }

  async closeDevice(deviceId: string): Promise<void> {
    if (this.mode === 'usbManager') this.manager.closeDevice(deviceId);
    else await this.ddk.closeDevice(deviceId);
  }

  async closeAll(): Promise<void> {
    if (this.mode === 'usbManager') this.manager.closeAll();
    else await this.ddk.closeAll();
  }

  async clearSharedAndCloseAll(): Promise<void> {
    if (this.mode === 'usbManager') this.manager.clearSharedAndCloseAll();
    else await this.ddk.clearSharedAndCloseAll();
  }

  async setConfiguration(handle: UsbDeviceHandle, value: number, forceClaim: boolean): Promise<number> {
    if (handle.backendMode === 'usbManager') return this.manager.setConfiguration(handle, value, forceClaim);
    return this.ddk.setConfiguration(handle, value);
  }

  async setAlternate(handle: UsbDeviceHandle, interfaceNumber: number, alternate: number): Promise<number> {
    if (handle.backendMode === 'usbManager') return this.manager.setAlternate(handle, interfaceNumber, alternate);
    return await this.ddk.setAlternate(handle, interfaceNumber, alternate);
  }

  async controlTransfer(handle: UsbDeviceHandle, setup: Uint8Array, payload: Uint8Array,
    length: number, direction: number, timeout: number): Promise<UsbControlTransferResult> {
    if (handle.backendMode === 'usbManager') {
      return await this.manager.controlTransfer(handle, setup, payload, length, direction, timeout);
    }
    return await this.ddk.controlTransfer(handle, setup, payload, length, direction, timeout);
  }

  startTransfer(handle: UsbDeviceHandle, endpointAddress: number, direction: number, data: Uint8Array,
    expectedLength: number, timeout: number, flags: number): UsbTransferOperation {
    if (handle.backendMode === 'usbManager') {
      return this.manager.startTransfer(handle, endpointAddress, direction, data, expectedLength, timeout, flags);
    }
    return this.ddk.startTransfer(handle, endpointAddress, direction, data, expectedLength, timeout, flags);
  }
}
