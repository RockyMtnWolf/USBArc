import { common } from '@kit.AbilityKit';
import { UsbArcPreferences, UsbArcPreferencesData, UsbAutoShareRule } from '../services/UsbArcPreferences';
import { UsbBackgroundTaskMode, UsbBackgroundTaskState, sharedUsbBackgroundTaskManager } from '../services/UsbBackgroundTaskManager';
import { sharedUsbArcController } from '../services/UsbArcController';
import { UsbArcLifecycle } from '../services/UsbArcLifecycle';
import { UsbDeviceInfo, UsbIpServerStatus } from '../usb/UsbModels';

@Component
export struct UsbArcSettings {
  @StorageLink('usbArcPreferences') private storedPreferences: UsbArcPreferencesData = {
    host: '0.0.0.0', port: 3240, autoRequestPermission: false, autoShare: false,
    autoShareScope: 'all', maxClients: 4, forceClaim: false, backgroundTaskMode: 'off', rules: []
  };
  @StorageLink('usbArcDevices') private devices: Array<UsbDeviceInfo> = [];
  @StorageLink('usbArcServerStatus') private serverStatus: UsbIpServerStatus = {
    running: false, host: '0.0.0.0', port: 3240, clientCount: 0, sharedDeviceIds: [], lastError: ''
  };
  @StorageLink('usbArcActionMessage') private actionMessage: string = '';
  @StorageLink('usbArcTrayRegistered') private trayRegistered: boolean = false;
  @State private settings: UsbArcPreferencesData = {
    host: '0.0.0.0', port: 3240, autoRequestPermission: false, autoShare: false,
    autoShareScope: 'all', maxClients: 4, forceClaim: false, backgroundTaskMode: 'off', rules: []
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
  @State private busy: boolean = false;
  @State private wideLayout: boolean = true;
  @State private showDeviceRules: boolean = false;
  private statusTimer: number = -1;

  aboutToAppear(): void {
    this.copyStoredPreferences();
    this.backgroundState = sharedUsbBackgroundTaskManager.getState();
    this.statusTimer = setInterval((): void => {
      this.backgroundState = sharedUsbBackgroundTaskManager.getState();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
  }

  private copyStoredPreferences(): void {
    this.settings = UsbArcPreferences.copy(this.storedPreferences);
    this.hostText = this.settings.host;
    this.portText = `${this.settings.port}`;
    this.maxClientsText = `${this.settings.maxClients}`;
  }

  private async savePreferences(next: UsbArcPreferencesData): Promise<boolean> {
    if (this.busy) {
      return false;
    }
    this.busy = true;
    try {
      const saved: boolean = await sharedUsbArcController.updatePreferences(next);
      if (saved) {
        this.settings = sharedUsbArcController.getPreferences();
        this.hostText = this.settings.host;
        this.portText = `${this.settings.port}`;
        this.maxClientsText = `${this.settings.maxClients}`;
      }
      return saved;
    } finally {
      this.busy = false;
    }
  }

  private async setBooleanPreference(name: 'autoRequestPermission' | 'autoShare' | 'forceClaim', value: boolean): Promise<void> {
    const next: UsbArcPreferencesData = UsbArcPreferences.copy(this.settings);
    if (name === 'autoRequestPermission') {
      next.autoRequestPermission = value;
    } else if (name === 'autoShare') {
      next.autoShare = value;
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
    if (UsbArcPreferences.normalizeRule(rule) === undefined) {
      this.getUIContext().getPromptAction().showToast({ message: 'VID和PID各需填写1到4位十六进制数。' });
      return;
    }
    if (await sharedUsbArcController.addRule(rule)) {
      this.settings = sharedUsbArcController.getPreferences();
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
    if (await sharedUsbArcController.addRule(rule)) {
      this.settings = sharedUsbArcController.getPreferences();
    }
  }

  private async removeRule(id: string): Promise<void> {
    if (await sharedUsbArcController.removeRule(id)) {
      this.settings = sharedUsbArcController.getPreferences();
    }
  }

  private async chooseBackgroundMode(mode: UsbBackgroundTaskMode): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await sharedUsbArcController.setBackgroundMode(mode);
      this.settings = sharedUsbArcController.getPreferences();
      this.backgroundState = sharedUsbBackgroundTaskManager.getState();
    } finally {
      this.busy = false;
    }
  }

  private async exitApplication(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) {
      return;
    }
    this.busy = true;
    try {
      await UsbArcLifecycle.exit(context);
    } catch (_error) {
      this.busy = false;
      this.getUIContext().getPromptAction().showToast({ message: '退出时未能完成全部清理。' });
    }
  }

  @Builder
  private PreferenceRow(title: string, description: string, enabled: boolean,
    onChange: (value: boolean) => void) {
    Row({ space: 14 }) {
      Column({ space: 5 }) {
        Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
        Text(description).fontSize(12).fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: enabled })
        .enabled(!this.busy)
        .onChange((value: boolean): void => onChange(value))
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  private BackgroundModeButton(mode: UsbBackgroundTaskMode, title: string, description: string) {
    Column({ space: 6 }) {
      Text(title).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
      Text(description).fontSize(12).fontColor($r('sys.color.font_secondary'))
      Button(this.settings.backgroundTaskMode === mode ? '当前已选' : '启用')
        .enabled(!this.busy && (this.settings.backgroundTaskMode !== mode || !this.backgroundState.taskActive))
        .onClick((): void => { void this.chooseBackgroundMode(mode); })
    }
    .width('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.accent_soft'))
    .borderRadius(14)
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
        .enabled(!this.busy)
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
          Text('管理授权、设备共享策略、网络与后台运行方式')
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
          this.PreferenceRow('接入时请求系统授权',
            '只请求系统USB权限，不会静默批准。系统拒绝后，本次接入不再重复弹窗；拔出再接入可重新请求。',
            this.settings.autoRequestPermission,
            (value: boolean): void => { void this.setBooleanPreference('autoRequestPermission', value); })
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.card_border') })
        .borderRadius(22)

        Column({ space: 10 }) {
          Text('接口映射策略').fontSize(18).fontWeight(FontWeight.Medium)
          this.PreferenceRow('强制接管 USB 接口',
            '默认关闭。开启后USBArc会请求强制占用接口，可能影响本机正在使用该设备的软件。',
            this.settings.forceClaim,
            (value: boolean): void => { void this.setBooleanPreference('forceClaim', value); })
          Row({ space: 8 }) {
            TextInput({ placeholder: '监听地址', text: $$this.hostText })
              .enabled(!this.serverStatus.running)
              .layoutWeight(1)
            TextInput({ placeholder: '端口', text: $$this.portText })
              .type(InputType.Number)
              .enabled(!this.serverStatus.running)
              .width(110)
            TextInput({ placeholder: '客户端上限', text: $$this.maxClientsText })
              .type(InputType.Number)
              .width(112)
          }
          Button(this.serverStatus.running ? '先停止服务再修改监听地址或端口' : '保存接口设置')
            .enabled(!this.busy && !this.serverStatus.running)
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

          }
          .width(this.wideLayout ? '48%' : '100%')
          Column({ space: 18 }) {
        Column({ space: 8 }) {
          Text('自动共享').fontSize(18).fontWeight(FontWeight.Medium)
          this.PreferenceRow('自动共享符合条件的设备',
            '仅在系统已授权后共享。Windows仍需使用usbip-win2主动连接。',
            this.settings.autoShare,
            (value: boolean): void => { void this.setBooleanPreference('autoShare', value); })
          Row({ space: 10 }) {
            Button(this.settings.autoShareScope === 'all' ? '●  全部设备' : '○  全部设备')
              .enabled(!this.busy)
              .backgroundColor(this.settings.autoShareScope === 'all' ? $r('app.color.accent_soft') : $r('app.color.card_background'))
              .onClick((): void => { void this.setScope('all'); })
            Button(this.settings.autoShareScope === 'rules' ? '●  仅匹配规则' : '○  仅匹配规则')
              .enabled(!this.busy)
              .backgroundColor(this.settings.autoShareScope === 'rules' ? $r('app.color.accent_soft') : $r('app.color.card_background'))
              .onClick((): void => { void this.setScope('rules'); })
          }
          Text('规则只匹配十六进制VID/PID。序列号匹配仅在系统实际提供可读序列号时生效；不可读取时USBArc不会猜测。')
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
              .enabled(!this.busy)
              .onClick((): void => { void this.addManualRule(); })
          }
          if (this.devices.length > 0) {
            Button(this.showDeviceRules ? '收起设备列表' : `从当前 ${this.devices.length} 台设备添加规则`)
              .enabled(!this.busy)
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
                  .enabled(!this.busy)
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
          Text('后台任务').fontSize(18).fontWeight(FontWeight.Medium)
          Text('只显示系统实际确认的任务状态；系统可随时暂停或结束。')
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
          this.BackgroundModeButton('off', '关闭', '不申请后台长时任务。')
          this.BackgroundModeButton('download', '数据传输任务（无下载内容）',
            '申请系统数据传输类别；不会下载文件、生成网络流量或显示虚假进度。任务没有真实数据传输时，系统可能取消它。')
          this.BackgroundModeButton('taskKeeping', '系统任务维持',
            '仅适用于PC/2-in-1。系统确认后才显示运行；系统仍可暂停或结束任务。')
          Text(this.backgroundState.taskActive ?
            `系统任务运行中：${this.backgroundState.activeModes.join(', ')}` : '系统任务当前未运行')
            .fontSize(13).fontWeight(FontWeight.Medium)
          Text(this.backgroundState.message)
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
          Text(this.trayRegistered ? '系统托盘入口已注册。关闭窗口会隐藏到托盘。' : '系统托盘入口不可用时，关闭窗口会按系统默认行为处理。')
            .fontSize(12).fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.card_border') })
        .borderRadius(22)

          }
          .width(this.wideLayout ? '48%' : '100%')
        }
        .width('100%')


        if (this.actionMessage.length > 0) {
          Text(this.actionMessage).fontSize(12).fontColor($r('sys.color.font_secondary'))
        }
        Button('退出 USBArc 并释放USB、服务和托盘任务')
          .enabled(!this.busy)
          .onClick((): void => { void this.exitApplication(); })
      }
      .width('100%')
      .constraintSize({ maxWidth: 1440 })
      .padding({ left: this.wideLayout ? 32 : 18, right: this.wideLayout ? 32 : 18, bottom: 28 })
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
