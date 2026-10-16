import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { UsbArcPreferences, UsbArcPreferencesData, UsbArcThemeMode, UsbAutoShareRule } from '../services/UsbArcPreferences';
import { UsbArcThemeController } from '../services/UsbArcThemeController';
import { UsbBackgroundTaskMode, UsbBackgroundTaskState, sharedUsbBackgroundTaskManager } from '../services/UsbBackgroundTaskManager';
import { sharedUsbArcController } from '../services/UsbArcController';
import { PreferenceOptionButton } from './PreferenceOptionButton';
import { PreferenceSwitchRow } from './PreferenceSwitchRow';
import { UsbDeviceInfo, UsbIpServerStatus } from '../usb/UsbModels';

type UsbArcPreferenceField = 'backendMode' | 'host' | 'port' | 'autoRequestPermission' | 'autoShare' |
  'autoShareScope' | 'maxClients' | 'forceClaim' | 'retainClaimsOnStop' | 'backgroundTaskMode' | 'themeMode' |
  'tabBarStyle' | 'tabBarImagePath' | 'appBackgroundEnabled' | 'rules';
const USB_ARC_SETTINGS_DOMAIN: number = 0x0000;
const USB_ARC_SETTINGS_TAG: string = 'UsbArcSettings';

@Component
export struct UsbArcSettings {
  @StorageLink('usbArcDevices') private devices: Array<UsbDeviceInfo> = [];
  @StorageLink('usbArcServerStatus') private serverStatus: UsbIpServerStatus = {
    running: false, host: '0.0.0.0', port: 3240, clientCount: 0,
    sharedDeviceIds: [], occupiedDeviceIds: [], listenerFamilies: [], lastError: ''
  };
  @StorageLink('usbArcActionMessage') private actionMessage: string = '';
  @State private settings: UsbArcPreferencesData = {
    backendMode: 'usbManager',
    host: '0.0.0.0', port: 3240, autoRequestPermission: false, autoShare: false,
    autoShareScope: 'all', maxClients: 4, forceClaim: false, backgroundTaskMode: 'off',
    retainClaimsOnStop: false,
    themeMode: 'system', tabBarStyle: 'material', tabBarImagePath: '', appBackgroundEnabled: false, rules: []
  };
  @State private hostText: string = '0.0.0.0';
  @State private portText: string = '3240';
  @State private maxClientsText: string = '4';
  @State private vendorInput: string = '';
  @State private productInput: string = '';
  @State private serialInput: string = '';
  @State private backgroundState: UsbBackgroundTaskState = {
    ok: true, selectedMode: 'off', taskActive: false, activeModes: [], suppressedBySystem: false,
    message: '后台任务已关闭。'
  };
  @State private backgroundTaskPending: boolean = false;
  @State private pendingPreferenceFields: Array<UsbArcPreferenceField> = [];
  @State private pickingTabBarImage: boolean = false;
  @State private wideLayout: boolean = true;
  @State private showDeviceRules: boolean = false;
  private preferenceSaveQueue: Promise<void> = Promise.resolve();
  private preferenceRevision: number = 0;
  private themeRevision: number = 0;
  private preferenceFieldRevisions: Map<string, number> = new Map<string, number>();
  private unsubscribeBackgroundState: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    this.copyStoredPreferences();
    this.backgroundState = sharedUsbBackgroundTaskManager.getState();
    this.unsubscribeBackgroundState = sharedUsbBackgroundTaskManager.subscribe((state: UsbBackgroundTaskState): void => {
      const wasActive: boolean = this.backgroundState.taskActive;
      this.backgroundState = state;
      if (wasActive && !state.taskActive && state.suppressedBySystem) {
        this.getUIContext().getPromptAction().showToast({ message: state.message });
      }
    });
  }

  aboutToDisappear(): void {
    if (this.unsubscribeBackgroundState !== undefined) {
      this.unsubscribeBackgroundState();
      this.unsubscribeBackgroundState = undefined;
    }
  }

  private copyStoredPreferences(): void {
    const persisted: UsbArcPreferencesData = sharedUsbArcController.getPreferences();
    const current: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
    const pending: Array<UsbArcPreferenceField> = [];
    for (let index: number = 0; index < this.pendingPreferenceFields.length; index++) {
      pending.push(this.pendingPreferenceFields[index]);
    }
    this.settings = this.mergePreferenceFields(persisted, current, pending);
    this.hostText = this.settings.host;
    this.portText = `${this.settings.port}`;
    this.maxClientsText = `${this.settings.maxClients}`;
  }

  private async savePreferences(next: UsbArcPreferencesData): Promise<boolean> {
    const previous: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
    const fields: Array<UsbArcPreferenceField> = this.changedPreferenceFields(previous, next);
    if (fields.length === 0) return true;
    const revision: number = ++this.preferenceRevision;
    hilog.info(USB_ARC_SETTINGS_DOMAIN, USB_ARC_SETTINGS_TAG,
      'Preference save begin. fields=%{public}s revision=%{public}d', fields.join(','), revision);
    for (let index: number = 0; index < fields.length; index++) {
      this.preferenceFieldRevisions.set(fields[index], revision);
    }
    this.settings = UsbArcPreferences.copy(next);
    for (let index: number = 0; index < fields.length; index++) {
      if (!this.pendingPreferenceFields.includes(fields[index])) {
        this.pendingPreferenceFields.push(fields[index]);
      }
    }
    let saved: boolean = false;
    const operation: Promise<void> = this.preferenceSaveQueue.then(async (): Promise<void> => {
      const latest: UsbArcPreferencesData = sharedUsbArcController.getPreferences();
      const merged: UsbArcPreferencesData = this.mergePreferenceFields(latest, next, fields);
      saved = await sharedUsbArcController.updatePreferences(merged, fields);
      if (saved) {
        hilog.info(USB_ARC_SETTINGS_DOMAIN, USB_ARC_SETTINGS_TAG,
          'Preference save commit. fields=%{public}s revision=%{public}d', fields.join(','), revision);
      } else {
        hilog.warn(USB_ARC_SETTINGS_DOMAIN, USB_ARC_SETTINGS_TAG,
          'Preference save fail. fields=%{public}s revision=%{public}d', fields.join(','), revision);
        const persisted: UsbArcPreferencesData = sharedUsbArcController.getPreferences();
        const rollbackFields: Array<UsbArcPreferenceField> = fields.filter((field: UsbArcPreferenceField): boolean =>
          this.preferenceFieldRevisions.get(field) === revision);
        if (rollbackFields.length > 0) {
          this.settings = this.mergePreferenceFields(this.settings, persisted, rollbackFields);
          this.hostText = this.settings.host;
          this.portText = `${this.settings.port}`;
          this.maxClientsText = `${this.settings.maxClients}`;
          this.getUIContext().getPromptAction().showToast({ message: this.preferenceFailureMessage() });
        }
      }
    });
    this.preferenceSaveQueue = operation.catch((): void => {});
    try {
      await operation;
      return saved;
    } catch (_error) {
      hilog.error(USB_ARC_SETTINGS_DOMAIN, USB_ARC_SETTINGS_TAG,
        'Preference save fail. fields=%{public}s revision=%{public}d', fields.join(','), revision);
      const persisted: UsbArcPreferencesData = sharedUsbArcController.getPreferences();
      const rollbackFields: Array<UsbArcPreferenceField> = fields.filter((field: UsbArcPreferenceField): boolean =>
        this.preferenceFieldRevisions.get(field) === revision);
      if (rollbackFields.length > 0) {
        this.settings = this.mergePreferenceFields(this.settings, persisted, rollbackFields);
        this.hostText = this.settings.host;
        this.portText = `${this.settings.port}`;
        this.getUIContext().getPromptAction().showToast({ message: this.preferenceFailureMessage() });
      }
      return false;
    } finally {
      this.pendingPreferenceFields = this.pendingPreferenceFields.filter((field: UsbArcPreferenceField): boolean =>
        !fields.includes(field) || this.preferenceFieldRevisions.get(field) !== revision);
    }
  }

  private isPreferencePending(field: UsbArcPreferenceField): boolean {
    return this.pendingPreferenceFields.includes(field);
  }

  private preferenceFailureMessage(): string {
    return this.actionMessage.indexOf('保存设置失败：') === 0 ? this.actionMessage : '设置保存失败。';
  }

  private changedPreferenceFields(previous: UsbArcPreferencesData, next: UsbArcPreferencesData): Array<UsbArcPreferenceField> {
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
    if (!this.sameRules(previous.rules, next.rules)) fields.push('rules');
    return fields;
  }

  private sameRules(left: Array<UsbAutoShareRule>, right: Array<UsbAutoShareRule>): boolean {
    if (left.length !== right.length) return false;
    for (let index: number = 0; index < left.length; index++) {
      if (left[index].id !== right[index].id || left[index].vendorIdHex !== right[index].vendorIdHex ||
        left[index].productIdHex !== right[index].productIdHex || left[index].serialNumber !== right[index].serialNumber) {
        return false;
      }
    }
    return true;
  }

  private mergePreferenceFields(target: UsbArcPreferencesData, source: UsbArcPreferencesData,
    fields: Array<UsbArcPreferenceField>): UsbArcPreferencesData {
    const merged: UsbArcPreferencesData = UsbArcPreferences.copy(target);
    for (let index: number = 0; index < fields.length; index++) {
      switch (fields[index]) {
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
        case 'rules': merged.rules = source.rules.slice(); break;
      }
    }
    return merged;
  }

  private async setBooleanPreference(name: 'autoRequestPermission' | 'autoShare' | 'forceClaim' | 'retainClaimsOnStop', value: boolean): Promise<void> {
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
    if (name === 'autoRequestPermission') {
      next.autoRequestPermission = value;
    } else if (name === 'autoShare') {
      next.autoShare = value;
    } else if (name === 'retainClaimsOnStop') {
      next.retainClaimsOnStop = value;
    } else {
      next.forceClaim = value;
    }
    await this.savePreferences(next);
  }

  private async setScope(scope: 'all' | 'rules'): Promise<void> {
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
    next.autoShareScope = scope;
    await this.savePreferences(next);
  }

  private async setBackendMode(mode: 'usbManager' | 'usbDdk'): Promise<void> {
    if (this.serverStatus.running) {
      return;
    }
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
    next.backendMode = mode;
    await this.savePreferences(next);
  }

  private async saveNetworkSettings(): Promise<void> {
    const port: number = Number(this.portText.trim());
    const maxClients: number = Number(this.maxClientsText.trim());
    const host: string = this.hostText.trim();
    if (host.length === 0 || !Number.isInteger(port) || port < 1 || port > 65535 ||
      !Number.isInteger(maxClients) || maxClients < 1 || maxClients > 32) {
      this.getUIContext().getPromptAction().showToast({ message: '监听地址不能为空；端口范围1–65535，客户端数范围1–32。' });
      return;
    }
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
    next.host = host;
    next.port = port;
    next.maxClients = maxClients;
    await this.savePreferences(next);
  }

  private async addManualRule(): Promise<void> {
    const rule: UsbAutoShareRule = {
      id: `${Date.now()}-${this.vendorInput}-${this.productInput}`,
      vendorIdHex: this.vendorInput,
      productIdHex: this.productInput,
      serialNumber: this.serialInput
    };
    const normalized: UsbAutoShareRule | undefined = UsbArcPreferences.normalizeRule(rule);
    if (normalized === undefined) {
      this.getUIContext().getPromptAction().showToast({ message: 'VID和PID各需填写1到4位十六进制数。' });
      return;
    }
    if (this.settings.rules.some((item: UsbAutoShareRule): boolean =>
      item.vendorIdHex === normalized.vendorIdHex && item.productIdHex === normalized.productIdHex &&
      item.serialNumber === normalized.serialNumber)) {
      this.getUIContext().getPromptAction().showToast({ message: '这条自动共享规则已存在。' });
      return;
    }
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
    next.rules.push(normalized);
    if (await this.savePreferences(next)) {
      this.vendorInput = '';
      this.productInput = '';
      this.serialInput = '';
    }
  }

  private async addDeviceRule(device: UsbDeviceInfo): Promise<void> {
    const rule: UsbAutoShareRule = {
      id: `${Date.now()}-${device.id}`,
      vendorIdHex: device.vendorId.toString(16),
      productIdHex: device.productId.toString(16),
      serialNumber: device.serialNumber
    };
    const normalized: UsbAutoShareRule | undefined = UsbArcPreferences.normalizeRule(rule);
    if (normalized === undefined) {
      this.getUIContext().getPromptAction().showToast({ message: '无法读取该设备的 VID/PID。' });
      return;
    }
    if (this.settings.rules.some((item: UsbAutoShareRule): boolean =>
      item.vendorIdHex === normalized.vendorIdHex && item.productIdHex === normalized.productIdHex &&
      item.serialNumber === normalized.serialNumber)) return;
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
    next.rules.push(normalized);
    await this.savePreferences(next);
  }

  private async removeRule(id: string): Promise<void> {
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
    next.rules = next.rules.filter((item: UsbAutoShareRule): boolean => item.id !== id);
    await this.savePreferences(next);
  }

  private async chooseBackgroundMode(mode: UsbBackgroundTaskMode): Promise<void> {
    if (this.backgroundTaskPending) {
      this.getUIContext().getPromptAction().showToast({ message: '正在应用，请稍等…' });
      return;
    }
    this.backgroundTaskPending = true;
    this.getUIContext().getPromptAction().showToast({ message: '正在应用，请稍等…' });
    hilog.info(USB_ARC_SETTINGS_DOMAIN, USB_ARC_SETTINGS_TAG,
      'Background mode begin. mode=%{public}s', mode);
    try {
      const activated: boolean = await sharedUsbArcController.setBackgroundMode(mode);
      this.copyStoredPreferences();
      this.backgroundState = sharedUsbBackgroundTaskManager.getState();
      if (!activated) {
        hilog.warn(USB_ARC_SETTINGS_DOMAIN, USB_ARC_SETTINGS_TAG,
          'Background mode fail. mode=%{public}s', mode);
        const saveFailure: boolean = this.actionMessage.indexOf('后台任务已应用，但设置未保存') === 0;
        this.getUIContext().getPromptAction().showToast({
          message: saveFailure ? this.actionMessage :
            (this.backgroundState.message.length > 0 ? this.backgroundState.message : '系统未确认后台任务已启动。')
        });
      } else {
        hilog.info(USB_ARC_SETTINGS_DOMAIN, USB_ARC_SETTINGS_TAG,
          'Background mode ack. mode=%{public}s', mode);
      }
    } catch (_error) {
      hilog.error(USB_ARC_SETTINGS_DOMAIN, USB_ARC_SETTINGS_TAG,
        'Background mode fail. mode=%{public}s', mode);
      this.backgroundState = sharedUsbBackgroundTaskManager.getState();
      this.getUIContext().getPromptAction().showToast({
        message: this.backgroundState.message.length > 0 ? this.backgroundState.message : '后台任务启动失败。'
      });
    } finally {
      this.backgroundTaskPending = false;
    }
  }

  private async setBackgroundModeSwitch(mode: 'download' | 'taskKeeping', enabled: boolean): Promise<void> {
    if (enabled === this.isBackgroundModeActive(mode)) {
      return;
    }
    await this.chooseBackgroundMode(enabled ? mode : 'off');
  }

  private isBackgroundModeActive(mode: 'download' | 'taskKeeping'): boolean {
    const systemMode: string = mode === 'download' ? 'dataTransfer' : 'taskKeeping';
    return this.backgroundState.taskActive && this.backgroundState.activeModes.includes(systemMode);
  }

  private async setThemeMode(mode: UsbArcThemeMode): Promise<void> {
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
    next.themeMode = mode;
    const revision: number = ++this.themeRevision;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context !== undefined) {
      UsbArcThemeController.apply(context, mode);
    }
    const saved: boolean = await this.savePreferences(next);
    if (!saved && revision === this.themeRevision && context !== undefined) {
      UsbArcThemeController.apply(context, sharedUsbArcController.getPreferences().themeMode);
    }
  }

  private async setAppBackgroundEnabled(enabled: boolean): Promise<void> {
    if (enabled && this.settings.tabBarImagePath.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请先选择一张本地图片。' });
      return;
    }
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
    next.appBackgroundEnabled = enabled;
    await this.savePreferences(next);
  }

  private async resetBackgroundImage(): Promise<void> {
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
    next.tabBarImagePath = '';
    next.appBackgroundEnabled = false;
    await this.savePreferences(next);
  }

  private async selectTabBarImage(): Promise<void> {
    if (this.pickingTabBarImage) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      return;
    }
    this.pickingTabBarImage = true;
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      if (result.photoUris.length === 0) {
        return;
      }
      const source = fileIo.openSync(result.photoUris[0], fileIo.OpenMode.READ_ONLY);
      const path: string = `${context.filesDir}/usbarc-tabbar-background`;
      let destination: fileIo.File | undefined;
      try {
        destination = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        await fileIo.copyFile(source.fd, destination.fd);
      } finally {
        fileIo.closeSync(source);
        if (destination !== undefined) {
          fileIo.closeSync(destination);
        }
      }
      const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
      next.tabBarImagePath = path;
      await this.savePreferences(next);
    } catch (_error) {
      this.getUIContext().getPromptAction().showToast({ message: '无法读取所选图片，请重试。' });
    } finally {
      this.pickingTabBarImage = false;
    }
  }

  @Builder
  private RuleRow(rule: UsbAutoShareRule) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(`VID ${rule.vendorIdHex.toUpperCase()}  ·  PID ${rule.productIdHex.toUpperCase()}`)
          .fontSize(14).fontWeight(FontWeight.Medium)
        Text(rule.serialNumber.length > 0 ? `序列号 ${rule.serialNumber}` : '匹配所有该VID/PID设备')
          .fontSize(12).fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button('删除')
        .onClick((): void => { void this.removeRule(rule.id); })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Column({ space: 6 }) {
          Text('设置')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
          Text('管理 USB 授权、共享策略、网络与应用外观')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 24, bottom: 8 })

        Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Start }) {
          Column({ space: 18 }) {
        Column({ space: 8 }) {
          Text('自动授权请求').fontSize(18).fontWeight(FontWeight.Medium)
          PreferenceSwitchRow({
            title: '接入时请求系统授权',
            description: '只请求系统USB权限，不会静默批准。系统拒绝后，本次接入不再重复弹窗；拔出再接入可重新请求。',
            checked: this.settings.autoRequestPermission,
            pending: this.isPreferencePending('autoRequestPermission'),
            onChange: (value: boolean): void => { void this.setBooleanPreference('autoRequestPermission', value); }
          })
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.card_border') })
        .borderRadius(22)

        Column({ space: 8 }) {
          Text('USB 接口后端').fontSize(18).fontWeight(FontWeight.Medium)
          Text('选择设备访问方式。USB Manager 是当前可用的通用后端。')
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
          Row({ space: 8 }) {
            PreferenceOptionButton({
              title: 'USB Manager',
              selected: this.settings.backendMode === 'usbManager',
              isEnabled: !this.serverStatus.running,
            onSelected: (): void => { void this.setBackendMode('usbManager'); }
            })
            PreferenceOptionButton({
              title: 'USB DDK',
              selected: this.settings.backendMode === 'usbDdk',
              isEnabled: !this.serverStatus.running,
              onSelected: (): void => { void this.setBackendMode('usbDdk'); }
            })
          }
          if (this.settings.backendMode === 'usbDdk') {
            Text('此构建尚未接入可用于通用 USB/IP 的 DDK 驱动扩展。选择 DDK 后服务会明确报告不可用并拒绝启动，不会自动切回 USB Manager。')
              .fontSize(12).fontColor($r('sys.color.font_secondary'))
          }
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.card_border') })
        .borderRadius(22)

        Column({ space: 10 }) {
          Text('接口映射策略').fontSize(18).fontWeight(FontWeight.Medium)
          PreferenceSwitchRow({
            title: '强制接管 USB 接口',
            description: '默认关闭。开启后USBArc会请求强制占用接口，可能影响本机正在使用该设备的软件。',
            checked: this.settings.forceClaim,
            pending: this.isPreferencePending('forceClaim'),
            onChange: (value: boolean): void => { void this.setBooleanPreference('forceClaim', value); }
          })
          Row({ space: 8 }) {
            Column({ space: 4 }) {
              Text('监听地址').fontSize(12).fontColor($r('sys.color.font_secondary'))
              TextInput({ placeholder: '0.0.0.0', text: $$this.hostText })
                .enabled(!this.serverStatus.running)
            }
            .layoutWeight(1)
            Column({ space: 4 }) {
              Text('端口').fontSize(12).fontColor($r('sys.color.font_secondary'))
              TextInput({ placeholder: '3240', text: $$this.portText })
                .type(InputType.Number)
                .enabled(!this.serverStatus.running)
            }
            .width(100)
            Column({ space: 4 }) {
              Text('最大客户端').fontSize(12).fontColor($r('sys.color.font_secondary'))
              TextInput({ placeholder: '4', text: $$this.maxClientsText })
                .type(InputType.Number)
            }
            .width(112)
          }
          Button(this.serverStatus.running ? '先停止服务再修改监听地址或端口' : '保存接口设置')
            .enabled(!this.serverStatus.running)
            .onClick((): void => { void this.saveNetworkSettings(); })
          Text('0.0.0.0表示监听所有网络接口。USB/IP没有内置认证或加密，请仅在可信网络或现有VPN内使用。')
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.card_border') })
        .borderRadius(22)

        Column({ space: 10 }) {
          Text('应用外观').fontSize(18).fontWeight(FontWeight.Medium)
          Row({ space: 8 }) {
            PreferenceOptionButton({
              title: '跟随系统',
              selected: this.settings.themeMode === 'system',
              onSelected: (): void => { void this.setThemeMode('system'); }
            })
            PreferenceOptionButton({
              title: '明亮',
              selected: this.settings.themeMode === 'light',
              onSelected: (): void => { void this.setThemeMode('light'); }
            })
            PreferenceOptionButton({
              title: '黑暗',
              selected: this.settings.themeMode === 'dark',
              onSelected: (): void => { void this.setThemeMode('dark'); }
            })
          }
          Text('整页背景图片').fontSize(15).fontWeight(FontWeight.Medium)
          Row({ space: 8 }) {
            Button(this.pickingTabBarImage ? '正在选择…' : '选择本地图片')
              .enabled(!this.pickingTabBarImage)
              .onClick((): void => { void this.selectTabBarImage(); })
            Button('重置图片')
              .enabled(this.settings.tabBarImagePath.length > 0)
              .onClick((): void => { void this.resetBackgroundImage(); })
          }
          PreferenceSwitchRow({
            title: '在整个应用中显示此图片',
            description: this.settings.tabBarImagePath.length > 0 ? '' : '先选择本地图片，再开启整页背景。',
            checked: this.settings.appBackgroundEnabled,
            pending: this.isPreferencePending('appBackgroundEnabled'),
            onChange: (value: boolean): void => { void this.setAppBackgroundEnabled(value); }
          })
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.card_border') })
        .borderRadius(22)

          }
          .width(this.wideLayout ? '45%' : '100%')
          .margin({ left: this.wideLayout ? 12 : 0, right: this.wideLayout ? 12 : 0 })
          Column({ space: 18 }) {
        Column({ space: 8 }) {
          Text('自动共享').fontSize(18).fontWeight(FontWeight.Medium)
          PreferenceSwitchRow({
            title: '自动共享符合条件的设备',
            description: '仅在系统已授权后共享。Windows仍需使用usbip-win2主动连接。',
            checked: this.settings.autoShare,
            pending: this.isPreferencePending('autoShare'),
            onChange: (value: boolean): void => { void this.setBooleanPreference('autoShare', value); }
          })
          Row({ space: 10 }) {
            Button(this.settings.autoShareScope === 'all' ? '●  全部设备' : '○  全部设备')
              .fontColor(this.settings.autoShareScope === 'all' ? $r('app.color.accent') : $r('sys.color.font_primary'))
              .backgroundColor(this.settings.autoShareScope === 'all' ? $r('app.color.accent_soft') : $r('app.color.card_background'))
              .border({ width: 1, color: this.settings.autoShareScope === 'all' ? $r('app.color.accent') : $r('app.color.card_border') })
              .onClick((): void => { void this.setScope('all'); })
            Button(this.settings.autoShareScope === 'rules' ? '●  仅匹配规则' : '○  仅匹配规则')
              .fontColor(this.settings.autoShareScope === 'rules' ? $r('app.color.accent') : $r('sys.color.font_primary'))
              .backgroundColor(this.settings.autoShareScope === 'rules' ? $r('app.color.accent_soft') : $r('app.color.card_background'))
              .border({ width: 1, color: this.settings.autoShareScope === 'rules' ? $r('app.color.accent') : $r('app.color.card_border') })
              .onClick((): void => { void this.setScope('rules'); })
          }
          Text('规则只匹配十六进制VID/PID。序列号匹配仅在系统实际提供可读序列号时生效；不可读取时无效。')
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
          ForEach(this.settings.rules, (rule: UsbAutoShareRule) => {
            this.RuleRow(rule)
          }, (rule: UsbAutoShareRule): string => rule.id)
          Row({ space: 8 }) {
            TextInput({ placeholder: 'VID，如 1234', text: $$this.vendorInput })
              .maxLength(4).layoutWeight(1)
            TextInput({ placeholder: 'PID，如 abcd', text: $$this.productInput })
              .maxLength(4).layoutWeight(1)
          }
          Row({ space: 8 }) {
            TextInput({ placeholder: '序列号（可选）', text: $$this.serialInput })
              .layoutWeight(1)
            Button('添加规则')
              .onClick((): void => { void this.addManualRule(); })
          }
          if (this.devices.length > 0) {
            Button(this.showDeviceRules ? '收起设备列表' : `从当前 ${this.devices.length} 台设备添加规则`)
              .onClick((): void => { this.showDeviceRules = !this.showDeviceRules; })
            if (this.showDeviceRules) {
              ForEach(this.devices, (device: UsbDeviceInfo) => {
              Row({ space: 10 }) {
                Text(`${device.product.length > 0 ? device.product : device.name} · ${device.vendorId.toString(16).padStart(4, '0')}:${device.productId.toString(16).padStart(4, '0')}`)
                  .fontSize(12)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Button('保存为规则')
                  .onClick((): void => { void this.addDeviceRule(device); })
              }
              .width('100%')
              .padding({ top: 4, bottom: 4 })
              }, (device: UsbDeviceInfo): string => device.id)
            }
          }
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.card_border') })
        .borderRadius(22)

        Column({ space: 10 }) {
          Text('模拟任务保活').fontSize(18).fontWeight(FontWeight.Medium)
          PreferenceSwitchRow({
            title: '任务保持',
            description: '推荐模式，仅 PC/二合一设备支持。',
            checked: this.isBackgroundModeActive('taskKeeping'),
            pending: this.backgroundTaskPending,
            toggleEnabled: !this.backgroundTaskPending,
            onChange: (value: boolean): void => { void this.setBackgroundModeSwitch('taskKeeping', value); }
          })
          PreferenceSwitchRow({
            title: '模拟下载',
            description: '',
            checked: this.isBackgroundModeActive('download'),
            pending: this.backgroundTaskPending,
            toggleEnabled: !this.backgroundTaskPending,
            onChange: (value: boolean): void => { void this.setBackgroundModeSwitch('download', value); }
          })
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.card_border') })
        .borderRadius(22)

        Column({ space: 8 }) {
          Text('停止服务时').fontSize(18).fontWeight(FontWeight.Medium)
          PreferenceSwitchRow({
            title: '停止后保持设备占用',
            description: '关闭后停止服务会释放 USB 设备；下次启动时由客户端重新占用。',
            checked: this.settings.retainClaimsOnStop,
            pending: this.isPreferencePending('retainClaimsOnStop'),
            onChange: (value: boolean): void => { void this.setBooleanPreference('retainClaimsOnStop', value); }
          })
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.card_border') })
        .borderRadius(22)

          }
          .width(this.wideLayout ? '45%' : '100%')
          .margin({ left: this.wideLayout ? 12 : 0, right: this.wideLayout ? 12 : 0 })
        }
        .width('100%')


      }
      .width('100%')
      .constraintSize({ maxWidth: 1440 })
      .padding({ left: this.wideLayout ? 32 : 18, right: this.wideLayout ? 32 : 18, bottom: 100 })
      .alignSelf(ItemAlign.Center)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      this.wideLayout = newValue.width >= 1080;
    })
  }
}
