import { common } from '@kit.AbilityKit';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
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

export type UsbArcPreferenceField = 'backendMode' | 'host' | 'port' | 'autoRequestPermission' | 'autoShare' |
  'autoShareScope' | 'maxClients' | 'forceClaim' | 'retainClaimsOnStop' | 'backgroundTaskMode' | 'themeMode' |
  'tabBarStyle' | 'tabBarImagePath' | 'appBackgroundEnabled' | 'rules';

export class UsbArcController {
  private context?: common.UIAbilityContext;
  private preferences: UsbArcPreferencesData = UsbArcPreferences.copy({
    backendMode: 'usbManager',
    host: '0.0.0.0', port: 3240, autoRequestPermission: false, autoShare: false,
    autoShareScope: 'all', maxClients: 4, forceClaim: false, retainClaimsOnStop: false, backgroundTaskMode: 'off',
    themeMode: 'system', tabBarStyle: 'material', tabBarImagePath: '', appBackgroundEnabled: false, rules: []
  });
  private devices: Array<UsbDeviceInfo> = [];
  private serverStatus: UsbIpServerStatus = {
    running: false, host: '0.0.0.0', port: 3240, clientCount: 0, sharedDeviceIds: [],
    occupiedDeviceIds: [], listenerFamilies: [], lastError: ''
  };
  private unsubscribe?: () => void;
  private unsubscribeBackground?: () => void;
  private usbEventSubscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  private usbEventRefreshTimer: number = -1;
  private usbEventRefreshQueue: Promise<void> = Promise.resolve();
  private initialized: boolean = false;
  private shuttingDown: boolean = false;
  private lifecycleGeneration: number = 0;
  private readonly devicePolicy: UsbArcDevicePolicy = new UsbArcDevicePolicy();
  private sharingIds: Set<string> = new Set<string>();
  private policyQueue: Promise<void> = Promise.resolve();
  private autoPolicyQueue: Promise<void> = Promise.resolve();
  private preferencesWriteQueue: Promise<void> = Promise.resolve();
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
    await this.subscribeUsbEvents(generation);
    if (this.shuttingDown || generation !== this.lifecycleGeneration) return;
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
      occupiedDeviceIds: this.serverStatus.occupiedDeviceIds.slice(),
      listenerFamilies: this.serverStatus.listenerFamilies.slice(),
      lastError: this.serverStatus.lastError
    };
  }

  setTrayRegistered(registered: boolean): void {
    AppStorage.setOrCreate(TRAY_STATE_KEY, registered);
  }

  async refresh(): Promise<void> {
    try {
      const devices: Array<UsbDeviceInfo> = await UsbIpServer.refreshDevices();
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
      this.scheduleAutoPolicyForPresentDevices();
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

  async updatePreferences(next: UsbArcPreferencesData,
    changedFields?: Array<UsbArcPreferenceField>): Promise<boolean> {
    const context: common.UIAbilityContext | undefined = this.context;
    if (context === undefined) {
      return false;
    }
    const fields: Array<UsbArcPreferenceField> = changedFields === undefined ?
      this.findChangedPreferenceFields(this.preferences, next) : changedFields.slice();
    if (fields.length === 0) return true;
    let saved: boolean = false;
    const operation: Promise<void> = this.preferencesWriteQueue.then(async (): Promise<void> => {
      const previous: UsbArcPreferencesData = UsbArcPreferences.copy(this.preferences);
      const merged: UsbArcPreferencesData = this.mergePreferenceFields(previous, next, fields);
      const backendModeChanged: boolean = merged.backendMode !== previous.backendMode;
      const autoRequestEnabled: boolean = merged.autoRequestPermission && !previous.autoRequestPermission;
      try {
        // Persist only the fields represented by this request. The USB SDK update stays synchronous.
        // If either operation fails, restore the old persisted/backend configuration.
        await UsbArcPreferences.save(context, merged);
        this.updateBackendSettings(merged);
        this.preferences = UsbArcPreferences.copy(merged);
        this.publishPreferences();
        if (autoRequestEnabled) {
          this.devices.forEach((device: UsbDeviceInfo): void => {
            if (!device.authorized) this.devicePolicy.resetPermissionAttempt(device.id);
          });
        }
        if (this.hasAutoPolicyChanges(fields)) {
          this.scheduleAutoPolicyForPresentDevices();
        }
        if (backendModeChanged) void this.refresh();
        saved = true;
      } catch (error) {
        try {
          await UsbArcPreferences.save(context, previous);
          this.updateBackendSettings(previous);
        } catch (_rollbackError) {
          // Keep the primary error visible; backend settings are restored whenever possible.
        }
        this.preferences = previous;
        this.publishPreferences();
        this.setActionMessage(`保存设置失败：${this.errorMessage(error as Object)}`);
      }
    });
    this.preferencesWriteQueue = operation.catch((): void => {});
    await operation;
    return saved;
  }

  private findChangedPreferenceFields(previous: UsbArcPreferencesData,
    next: UsbArcPreferencesData): Array<UsbArcPreferenceField> {
    const fields: Array<UsbArcPreferenceField> = [];
    if (previous.backendMode !== next.backendMode) fields.push('backendMode');
    if (previous.host !== next.host) fields.push('host');
    if (previous.port !== next.port) fields.push('port');
    if (previous.autoRequestPermission !== next.autoRequestPermission) fields.push('autoRequestPermission');
    if (previous.autoShare !== next.autoShare) fields.push('autoShare');
    if (previous.autoShareScope !== next.autoShareScope) fields.push('autoShareScope');
    if (previous.maxClients !== next.maxClients) fields.push('maxClients');
    if (previous.forceClaim !== next.forceClaim) fields.push('forceClaim');
    if (previous.retainClaimsOnStop !== next.retainClaimsOnStop) fields.push('retainClaimsOnStop');
    if (previous.backgroundTaskMode !== next.backgroundTaskMode) fields.push('backgroundTaskMode');
    if (previous.themeMode !== next.themeMode) fields.push('themeMode');
    if (previous.tabBarStyle !== next.tabBarStyle) fields.push('tabBarStyle');
    if (previous.tabBarImagePath !== next.tabBarImagePath) fields.push('tabBarImagePath');
    if (previous.appBackgroundEnabled !== next.appBackgroundEnabled) fields.push('appBackgroundEnabled');
    const rulesChanged: boolean = previous.rules.length !== next.rules.length || previous.rules.some(
      (item: UsbAutoShareRule, index: number): boolean => {
        const candidate: UsbAutoShareRule | undefined = next.rules[index];
        return candidate === undefined || item.id !== candidate.id || item.vendorIdHex !== candidate.vendorIdHex ||
          item.productIdHex !== candidate.productIdHex || item.serialNumber !== candidate.serialNumber;
      });
    if (rulesChanged) fields.push('rules');
    return fields;
  }

  private mergePreferenceFields(base: UsbArcPreferencesData, source: UsbArcPreferencesData,
    fields: Array<UsbArcPreferenceField>): UsbArcPreferencesData {
    const merged: UsbArcPreferencesData = UsbArcPreferences.copy(base);
    fields.forEach((field: UsbArcPreferenceField): void => {
      switch (field) {
        case 'backendMode': merged.backendMode = source.backendMode; break;
        case 'host': merged.host = source.host; break;
        case 'port': merged.port = source.port; break;
        case 'autoRequestPermission': merged.autoRequestPermission = source.autoRequestPermission; break;
        case 'autoShare': merged.autoShare = source.autoShare; break;
        case 'autoShareScope': merged.autoShareScope = source.autoShareScope; break;
        case 'maxClients': merged.maxClients = source.maxClients; break;
        case 'forceClaim': merged.forceClaim = source.forceClaim; break;
        case 'retainClaimsOnStop': merged.retainClaimsOnStop = source.retainClaimsOnStop; break;
        case 'backgroundTaskMode': merged.backgroundTaskMode = source.backgroundTaskMode; break;
        case 'themeMode': merged.themeMode = source.themeMode; break;
        case 'tabBarStyle': merged.tabBarStyle = source.tabBarStyle; break;
        case 'tabBarImagePath': merged.tabBarImagePath = source.tabBarImagePath; break;
        case 'appBackgroundEnabled': merged.appBackgroundEnabled = source.appBackgroundEnabled; break;
        case 'rules': merged.rules = source.rules.map((rule: UsbAutoShareRule): UsbAutoShareRule => ({
          id: rule.id, vendorIdHex: rule.vendorIdHex, productIdHex: rule.productIdHex, serialNumber: rule.serialNumber
        })); break;
      }
    });
    return merged;
  }

  private hasAutoPolicyChanges(fields: Array<UsbArcPreferenceField>): boolean {
    return fields.some((field: UsbArcPreferenceField): boolean =>
      field === 'autoRequestPermission' || field === 'autoShare' || field === 'autoShareScope' ||
      field === 'rules' || field === 'backendMode' || field === 'forceClaim');
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
    return await this.updatePreferences(next, ['rules']);
  }

  async removeRule(ruleId: string): Promise<boolean> {
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.preferences);
    next.rules = next.rules.filter((item: UsbAutoShareRule): boolean => item.id !== ruleId);
    return await this.updatePreferences(next, ['rules']);
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
      const saved: boolean = await this.updatePreferences(next, ['backgroundTaskMode']);
      if (!saved) {
        this.publishBackgroundState();
        this.setActionMessage('后台任务已应用，但设置未保存。');
        return false;
      }
    }
    this.publishBackgroundState();
    if (!state.ok) this.setActionMessage(state.message);
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
      this.setActionMessage(granted ? '系统已授权该USB设备。' : '尚未获得授权（可能仍在等待系统确认）；请完成系统弹窗后刷新设备列表。');
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
    this.unsubscribeUsbEvents();
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

  private async subscribeUsbEvents(generation: number): Promise<void> {
    const subscribeInfo: commonEventManager.CommonEventSubscribeInfo = {
      events: [
        commonEventManager.Support.COMMON_EVENT_USB_DEVICE_ATTACHED,
        commonEventManager.Support.COMMON_EVENT_USB_DEVICE_DETACHED
      ]
    };
    let subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
    try {
      subscriber = await commonEventManager.createSubscriber(subscribeInfo);
      if (this.shuttingDown || generation !== this.lifecycleGeneration) {
        commonEventManager.unsubscribe(subscriber);
        return;
      }
      await commonEventManager.subscribeToEvent(subscriber, (event: commonEventManager.CommonEventData): void => {
        if (event.event === commonEventManager.Support.COMMON_EVENT_USB_DEVICE_ATTACHED ||
          event.event === commonEventManager.Support.COMMON_EVENT_USB_DEVICE_DETACHED) {
          this.scheduleUsbEventRefresh(generation);
        }
      });
      if (this.shuttingDown || generation !== this.lifecycleGeneration) {
        commonEventManager.unsubscribe(subscriber);
        return;
      }
      this.usbEventSubscriber = subscriber;
    } catch (error) {
      if (subscriber !== undefined) {
        try { commonEventManager.unsubscribe(subscriber); } catch (_unsubscribeError) { }
      }
      this.setActionMessage(`USB设备热插拔监听不可用：${this.errorMessage(error as Object)}`);
    }
  }

  private unsubscribeUsbEvents(): void {
    if (this.usbEventRefreshTimer >= 0) {
      clearTimeout(this.usbEventRefreshTimer);
      this.usbEventRefreshTimer = -1;
    }
    const subscriber: commonEventManager.CommonEventSubscriber | undefined = this.usbEventSubscriber;
    this.usbEventSubscriber = undefined;
    if (subscriber !== undefined) {
      try { commonEventManager.unsubscribe(subscriber); } catch (_error) { }
    }
  }

  private scheduleUsbEventRefresh(generation: number): void {
    if (this.shuttingDown || generation !== this.lifecycleGeneration) return;
    if (this.usbEventRefreshTimer >= 0) clearTimeout(this.usbEventRefreshTimer);
    this.usbEventRefreshTimer = setTimeout((): void => {
      this.usbEventRefreshTimer = -1;
      const refreshWork: Promise<void> = this.usbEventRefreshQueue.then(async (): Promise<void> => {
        if (!this.shuttingDown && generation === this.lifecycleGeneration) await this.refresh();
      }, async (): Promise<void> => {
        if (!this.shuttingDown && generation === this.lifecycleGeneration) await this.refresh();
      });
      this.usbEventRefreshQueue = refreshWork.catch((): void => {});
    }, 250);
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
    this.enqueueAutoPolicy(arrived, false);
  }

  private scheduleAutoPolicyForPresentDevices(): void {
    const current: Set<string> = this.devicePolicy.currentAttachmentIds();
    this.enqueueAutoPolicy(current, true);
  }

  private enqueueAutoPolicy(eligibleIds: Set<string>, settingsChanged: boolean): void {
    const allowedIds: Set<string> = new Set<string>(eligibleIds);
    const generation: number = this.lifecycleGeneration;
    const next: Promise<void> = this.autoPolicyQueue.then(async (): Promise<void> => {
      if (!this.shuttingDown && generation === this.lifecycleGeneration) {
        await this.applyAutoPolicy(this.devices.slice(), allowedIds, settingsChanged);
      }
    }, async (): Promise<void> => {
      if (!this.shuttingDown && generation === this.lifecycleGeneration) {
        await this.applyAutoPolicy(this.devices.slice(), allowedIds, settingsChanged);
      }
    });
    this.autoPolicyQueue = next.catch((error: Object): void => {
      this.setActionMessage(`自动设备策略执行失败：${this.errorMessage(error)}`);
    });
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
            this.setActionMessage(`尚未获得${this.deviceTitle(device)}的USB授权（可能仍在等待系统确认）；请完成系统弹窗后刷新设备列表。`);
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
    if (this.shuttingDown || !this.serverStatus.running || !this.preferences.autoShare || device.shared || !device.authorized || !device.available ||
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
    if (desired.backendMode !== current.backendMode) delta.backendMode = desired.backendMode;
    if (desired.autoRequestPermission !== current.autoRequestPermission) {
      delta.autoRequestPermission = desired.autoRequestPermission;
    }
    if (desired.autoShare !== current.autoShare) delta.autoShare = desired.autoShare;
    if (desired.maxClients !== current.maxClients) delta.maxClients = desired.maxClients;
    if (desired.forceClaim !== current.forceClaim) delta.forceClaim = desired.forceClaim;
    if (desired.retainClaimsOnStop !== current.retainClaimsOnStop) {
      delta.retainClaimsOnStop = desired.retainClaimsOnStop;
    }
    if (delta.host === undefined && delta.port === undefined && delta.backendMode === undefined &&
      delta.autoRequestPermission === undefined && delta.autoShare === undefined && delta.maxClients === undefined &&
      delta.forceClaim === undefined && delta.retainClaimsOnStop === undefined) {
      return;
    }
    UsbIpServer.updateSettings(delta);
  }

  private updateServerStatus(status: UsbIpServerStatus): void {
    this.serverStatus = {
      running: status.running,
      host: status.host,
      port: status.port,
      clientCount: status.clientCount,
      sharedDeviceIds: status.sharedDeviceIds.slice(),
      occupiedDeviceIds: status.occupiedDeviceIds.slice(),
      listenerFamilies: status.listenerFamilies.slice(),
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
