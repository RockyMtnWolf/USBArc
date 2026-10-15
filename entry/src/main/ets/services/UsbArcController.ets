import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { UsbIpServer } from './UsbIpServer';
import {
  UsbArcPreferences,
  UsbArcPreferencesData,
  UsbAutoShareRule
} from './UsbArcPreferences';
import { UsbBackgroundTaskManager, UsbBackgroundTaskMode, UsbBackgroundTaskState,
  sharedUsbBackgroundTaskManager } from './UsbBackgroundTaskManager';
import { UsbArcDevicePolicy } from './UsbArcDevicePolicy';
import { UsbDeviceInfo, UsbIpServerEvent, UsbIpServerSettings, UsbIpServerStatus } from '../usb/UsbModels';

const DEVICES_KEY: string = 'usbArcDevices';
const SERVER_STATUS_KEY: string = 'usbArcServerStatus';
const PREFERENCES_KEY: string = 'usbArcPreferences';
const BACKGROUND_STATE_KEY: string = 'usbArcBackgroundState';
const ACTION_MESSAGE_KEY: string = 'usbArcActionMessage';
const TRAY_STATE_KEY: string = 'usbArcTrayRegistered';

export class UsbArcController {
  private context?: common.UIAbilityContext;
  private preferences: UsbArcPreferencesData = UsbArcPreferences.copy({
    host: '0.0.0.0', port: 3240, autoRequestPermission: false, autoShare: false,
    autoShareScope: 'all', maxClients: 4, forceClaim: false, backgroundTaskMode: 'off', rules: []
  });
  private devices: Array<UsbDeviceInfo> = [];
  private serverStatus: UsbIpServerStatus = {
    running: false, host: '0.0.0.0', port: 3240, clientCount: 0, sharedDeviceIds: [], lastError: ''
  };
  private unsubscribe?: () => void;
  private unsubscribeBackground?: () => void;
  private initialized: boolean = false;
  private shuttingDown: boolean = false;
  private lifecycleGeneration: number = 0;
  private readonly devicePolicy: UsbArcDevicePolicy = new UsbArcDevicePolicy();
  private sharingIds: Set<string> = new Set<string>();
  private policyQueue: Promise<void> = Promise.resolve();
  private readonly backgroundTaskManager: UsbBackgroundTaskManager = sharedUsbBackgroundTaskManager;

  async initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      this.context = context;
      return;
    }
    this.context = context;
    this.shuttingDown = false;
    const generation: number = ++this.lifecycleGeneration;
    this.preferences = await UsbArcPreferences.load(context);
    if (this.shuttingDown || generation !== this.lifecycleGeneration) {
      return;
    }
    this.backgroundTaskManager.register(context);
    this.backgroundTaskManager.restoreSelection(this.preferences.backgroundTaskMode);
    this.unsubscribeBackground = this.backgroundTaskManager.subscribe((): void => this.publishBackgroundState());
    this.publishPreferences();
    this.publishBackgroundState();
    UsbIpServer.updateSettings(UsbArcPreferences.toServerSettings(this.preferences));
    this.unsubscribe = UsbIpServer.subscribe((event: UsbIpServerEvent): void => this.handleServerEvent(event));
    this.initialized = true;
    await this.refresh();
  }

  getPreferences(): UsbArcPreferencesData {
    return UsbArcPreferences.copy(this.preferences);
  }

  getDevices(): Array<UsbDeviceInfo> {
    return this.devices.slice();
  }

  getServerStatus(): UsbIpServerStatus {
    return {
      running: this.serverStatus.running,
      host: this.serverStatus.host,
      port: this.serverStatus.port,
      clientCount: this.serverStatus.clientCount,
      sharedDeviceIds: this.serverStatus.sharedDeviceIds.slice(),
      lastError: this.serverStatus.lastError
    };
  }

  setTrayRegistered(registered: boolean): void {
    AppStorage.setOrCreate(TRAY_STATE_KEY, registered);
  }

  async refresh(): Promise<void> {
    try {
      const devices: Array<UsbDeviceInfo> = await UsbIpServer.listDevices();
      await this.enqueueSnapshot(devices);
      this.updateServerStatus(UsbIpServer.getStatus());
    } catch (error) {
      this.setActionMessage(`读取USB设备失败：${this.errorMessage(error as Object)}`);
    }
  }

  async startServer(): Promise<boolean> {
    const context: common.UIAbilityContext | undefined = this.context;
    if (context === undefined || this.shuttingDown) {
      return false;
    }
    try {
      if (!UsbIpServer.getStatus().running) {
        UsbIpServer.updateSettings(UsbArcPreferences.toServerSettings(this.preferences));
      }
      await UsbIpServer.start();
      this.updateServerStatus(UsbIpServer.getStatus());
      if (this.preferences.backgroundTaskMode !== 'off') {
        await this.backgroundTaskManager.onServerStarted(context);
        this.publishBackgroundState();
      }
      this.setActionMessage(`USB/IP服务已在${this.serverStatus.host}:${this.serverStatus.port}启动。`);
      await this.refresh();
      return true;
    } catch (error) {
      const message: string = this.errorMessage(error as Object);
      this.setActionMessage(`USB/IP服务启动失败：${message}`);
      this.updateServerStatus(UsbIpServer.getStatus());
      return false;
    }
  }

  async stopServer(): Promise<boolean> {
    try {
      await UsbIpServer.stop();
      this.updateServerStatus(UsbIpServer.getStatus());
      this.setActionMessage('USB/IP服务已停止。');
      await this.refresh();
      return true;
    } catch (error) {
      this.setActionMessage(`停止USB/IP服务失败：${this.errorMessage(error as Object)}`);
      return false;
    }
  }

  async updatePreferences(next: UsbArcPreferencesData): Promise<boolean> {
    const context: common.UIAbilityContext | undefined = this.context;
    if (context === undefined) {
      return false;
    }
    try {
      this.updateBackendSettings(next);
      await UsbArcPreferences.save(context, next);
      this.preferences = UsbArcPreferences.copy(next);
      this.publishPreferences();
      await this.runAutoPolicyForPresentDevices();
      this.setActionMessage('设置已保存。');
      return true;
    } catch (error) {
      this.setActionMessage(`保存设置失败：${this.errorMessage(error as Object)}`);
      return false;
    }
  }

  async addRule(rule: UsbAutoShareRule): Promise<boolean> {
    const normalized: UsbAutoShareRule | undefined = UsbArcPreferences.normalizeRule(rule);
    if (normalized === undefined) {
      this.setActionMessage('VID和PID必须是1到4位十六进制数。');
      return false;
    }
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.preferences);
    const duplicate: boolean = next.rules.some((item: UsbAutoShareRule): boolean =>
      item.vendorIdHex === normalized.vendorIdHex && item.productIdHex === normalized.productIdHex &&
      item.serialNumber === normalized.serialNumber);
    if (duplicate) {
      this.setActionMessage('这条自动共享规则已存在。');
      return false;
    }
    next.rules.push(normalized);
    return await this.updatePreferences(next);
  }

  async removeRule(ruleId: string): Promise<boolean> {
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.preferences);
    next.rules = next.rules.filter((item: UsbAutoShareRule): boolean => item.id !== ruleId);
    return await this.updatePreferences(next);
  }

  async setBackgroundMode(mode: UsbBackgroundTaskMode): Promise<boolean> {
    const context: common.UIAbilityContext | undefined = this.context;
    if (context === undefined) {
      return false;
    }
    const state: UsbBackgroundTaskState = await this.backgroundTaskManager.setMode(context, mode);
    if (state.ok) {
      const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.preferences);
      next.backgroundTaskMode = mode;
      try {
        await UsbArcPreferences.save(context, next);
        this.preferences = next;
        this.publishPreferences();
      } catch (error) {
        this.setActionMessage(`系统已确认任务，但保存设置失败：${this.errorMessage(error as Object)}`);
      }
    }
    this.publishBackgroundState();
    this.setActionMessage(state.message);
    return state.ok;
  }

  async requestPermission(deviceId: string): Promise<boolean> {
    if (this.shuttingDown) {
      return false;
    }
    this.devicePolicy.markPermissionAttempted(deviceId);
    try {
      const granted: boolean = await UsbIpServer.requestPermission(deviceId);
      if (this.shuttingDown) {
        return false;
      }
      this.setActionMessage(granted ? '系统已授权该USB设备。' : '系统拒绝授权；当前接入期间不会重复弹窗。');
      await this.refresh();
      if (granted) {
        const device: UsbDeviceInfo | undefined = this.devices.find((item: UsbDeviceInfo): boolean => item.id === deviceId);
        if (device !== undefined) {
          await this.maybeAutoShare(device);
        }
      }
      return granted;
    } catch (error) {
      this.setActionMessage(`USB授权请求未完成：${this.errorMessage(error as Object)}`);
      return false;
    }
  }

  async shareDevice(deviceId: string): Promise<boolean> {
    if (this.shuttingDown) {
      return false;
    }
    const device: UsbDeviceInfo | undefined = this.devices.find((item: UsbDeviceInfo): boolean => item.id === deviceId);
    if (device === undefined) {
      this.setActionMessage('USB设备已断开，请刷新设备列表。');
      return false;
    }
    if (!device.authorized) {
      this.setActionMessage('请先通过系统弹窗授权此设备，再手动共享。');
      return false;
    }
    if (device.shared) {
      this.setActionMessage('此USB设备已经共享。');
      return true;
    }
    if (!this.devicePolicy.canManuallyShare(device)) {
      this.setActionMessage('此USB设备当前不可用，无法共享。');
      return false;
    }
    if (this.sharingIds.has(deviceId)) {
      return true;
    }
    this.sharingIds.add(deviceId);
    try {
      await UsbIpServer.share(deviceId);
      if (this.shuttingDown) {
        await UsbIpServer.unshare(deviceId);
        return false;
      }
      this.setActionMessage(`${this.deviceTitle(device)} 已共享。`);
      await this.refresh();
      return true;
    } catch (error) {
      this.setActionMessage(`共享设备失败：${this.errorMessage(error as Object)}`);
      return false;
    } finally {
      this.sharingIds.delete(deviceId);
    }
  }

  async unshareDevice(deviceId: string): Promise<boolean> {
    if (this.shuttingDown) {
      return false;
    }
    try {
      await UsbIpServer.unshare(deviceId);
      this.setActionMessage('USB设备已停止共享。');
      await this.refresh();
      return true;
    } catch (error) {
      this.setActionMessage(`停止共享失败：${this.errorMessage(error as Object)}`);
      return false;
    }
  }

  async shutdown(): Promise<void> {
    if (this.shuttingDown) {
      return;
    }
    this.shuttingDown = true;
    this.lifecycleGeneration++;
    if (this.unsubscribe !== undefined) {
      this.unsubscribe();
      this.unsubscribe = undefined;
    }
    if (this.unsubscribeBackground !== undefined) {
      this.unsubscribeBackground();
      this.unsubscribeBackground = undefined;
    }
    const deviceIds: Array<string> = this.devices.map((device: UsbDeviceInfo): string => device.id);
    for (let index: number = 0; index < deviceIds.length; index++) {
      try {
        await UsbIpServer.unshare(deviceIds[index]);
      } catch (_error) {
        // Stopping the server below also closes all device handles.
      }
    }
    try {
      await UsbIpServer.stop();
    } catch (_error) {
      // Ability destruction is best effort after USB unshare attempts.
    }
    if (this.context !== undefined) {
      await this.backgroundTaskManager.dispose(this.context);
    }
    this.updateServerStatus(UsbIpServer.getStatus());
    this.initialized = false;
  }

  private handleServerEvent(event: UsbIpServerEvent): void {
    this.updateServerStatus(event.status);
    if (event.kind === 'devices' || event.kind === 'status') {
      void this.enqueueSnapshot(event.devices);
    }
    if (event.kind === 'error' && event.message.length > 0) {
      this.setActionMessage(event.message);
    }
  }

  private enqueueSnapshot(devices: Array<UsbDeviceInfo>): Promise<void> {
    const snapshot: Array<UsbDeviceInfo> = devices.slice();
    const generation: number = this.lifecycleGeneration;
    const next: Promise<void> = this.policyQueue.then(async (): Promise<void> => {
      if (!this.shuttingDown && generation === this.lifecycleGeneration) {
        await this.applySnapshot(snapshot);
      }
    }, async (): Promise<void> => {
      if (!this.shuttingDown && generation === this.lifecycleGeneration) {
        await this.applySnapshot(snapshot);
      }
    });
    this.policyQueue = next.catch((): void => {});
    return next;
  }

  private async applySnapshot(snapshot: Array<UsbDeviceInfo>): Promise<void> {
    if (this.shuttingDown) {
      return;
    }
    const arrived: Set<string> = this.devicePolicy.updateAttachment(snapshot);
    this.devices = snapshot;
    this.publishDevices();
    await this.applyAutoPolicy(snapshot, arrived, false);
  }

  private async runAutoPolicyForPresentDevices(): Promise<void> {
    const current: Set<string> = this.devicePolicy.currentAttachmentIds();
    await this.applyAutoPolicy(this.devices, current, true);
  }

  private async applyAutoPolicy(snapshot: Array<UsbDeviceInfo>, eligibleIds: Set<string>,
    settingsChanged: boolean): Promise<void> {
    for (let index: number = 0; index < snapshot.length; index++) {
      if (this.shuttingDown) {
        return;
      }
      const device: UsbDeviceInfo = snapshot[index];
      if (!eligibleIds.has(device.id)) {
        continue;
      }
      if (this.preferences.autoRequestPermission && !device.authorized &&
        this.devicePolicy.shouldRequestPermission(device.id, true, device.authorized)) {
        try {
          const granted: boolean = await UsbIpServer.requestPermission(device.id);
          if (this.shuttingDown) {
            return;
          }
          if (!granted) {
            this.setActionMessage(`系统拒绝了${this.deviceTitle(device)}的USB授权；本次接入不再重复请求。`);
            continue;
          }
        } catch (error) {
          this.setActionMessage(`请求${this.deviceTitle(device)}的USB授权失败：${this.errorMessage(error as Object)}`);
          continue;
        }
        const updated: UsbDeviceInfo | undefined = await this.findDevice(device.id);
        if (updated !== undefined && !this.shuttingDown) {
          await this.maybeAutoShare(updated);
        }
        continue;
      }
      if (device.authorized || settingsChanged) {
        await this.maybeAutoShare(device);
      }
    }
  }

  private async maybeAutoShare(device: UsbDeviceInfo): Promise<void> {
    if (this.shuttingDown || !this.preferences.autoShare || device.shared || !device.authorized || !device.available ||
      this.sharingIds.has(device.id) ||
      !this.autoShareMatches(device)) {
      return;
    }
    this.sharingIds.add(device.id);
    try {
      await UsbIpServer.share(device.id);
      if (this.shuttingDown) {
        await UsbIpServer.unshare(device.id);
        return;
      }
      this.setActionMessage(`自动共享：${this.deviceTitle(device)}。`);
    } catch (error) {
      this.setActionMessage(`自动共享${this.deviceTitle(device)}失败：${this.errorMessage(error as Object)}`);
    } finally {
      this.sharingIds.delete(device.id);
    }
  }

  private autoShareMatches(device: UsbDeviceInfo): boolean {
    return this.devicePolicy.matchesAutoShare(this.preferences, device);
  }

  private async findDevice(deviceId: string): Promise<UsbDeviceInfo | undefined> {
    try {
      const current: Array<UsbDeviceInfo> = await UsbIpServer.listDevices();
      const latest: UsbDeviceInfo | undefined = current.find((device: UsbDeviceInfo): boolean => device.id === deviceId);
      if (latest !== undefined) {
        this.devices = current;
        this.publishDevices();
      }
      return latest;
    } catch (_error) {
      return undefined;
    }
  }

  private publishDevices(): void {
    AppStorage.setOrCreate(DEVICES_KEY, this.devices.slice());
  }

  private updateBackendSettings(next: UsbArcPreferencesData): void {
    const desired: UsbIpServerSettings = UsbArcPreferences.toServerSettings(next);
    const current: UsbIpServerSettings = UsbIpServer.getSettings();
    const delta: Partial<UsbIpServerSettings> = {};
    if (desired.host !== current.host) delta.host = desired.host;
    if (desired.port !== current.port) delta.port = desired.port;
    if (desired.autoRequestPermission !== current.autoRequestPermission) {
      delta.autoRequestPermission = desired.autoRequestPermission;
    }
    if (desired.autoShare !== current.autoShare) delta.autoShare = desired.autoShare;
    if (desired.maxClients !== current.maxClients) delta.maxClients = desired.maxClients;
    if (desired.forceClaim !== current.forceClaim) delta.forceClaim = desired.forceClaim;
    UsbIpServer.updateSettings(delta);
  }

  private updateServerStatus(status: UsbIpServerStatus): void {
    this.serverStatus = {
      running: status.running,
      host: status.host,
      port: status.port,
      clientCount: status.clientCount,
      sharedDeviceIds: status.sharedDeviceIds.slice(),
      lastError: status.lastError
    };
    AppStorage.setOrCreate(SERVER_STATUS_KEY, this.getServerStatus());
  }

  private publishPreferences(): void {
    AppStorage.setOrCreate(PREFERENCES_KEY, UsbArcPreferences.copy(this.preferences));
  }

  private publishBackgroundState(): void {
    AppStorage.setOrCreate(BACKGROUND_STATE_KEY, this.backgroundTaskManager.getState());
  }

  private setActionMessage(message: string): void {
    AppStorage.setOrCreate(ACTION_MESSAGE_KEY, message);
  }

  deviceTitle(device: UsbDeviceInfo): string {
    const label: string = device.product.length > 0 ? device.product : device.name;
    return label.length > 0 ? label : `USB ${this.hexId(device.vendorId)}:${this.hexId(device.productId)}`;
  }

  hexId(value: number): string {
    return value.toString(16).padStart(4, '0').toUpperCase();
  }

  private errorMessage(error: Object): string {
    const businessError: BusinessError = error as BusinessError;
    return businessError.message ?? `错误码${businessError.code ?? 'unknown'}`;
  }
}

export const sharedUsbArcController: UsbArcController = new UsbArcController();
