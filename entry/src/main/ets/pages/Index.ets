import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { UsbArcSettings } from '../components/UsbArcSettings';
import { UsbDeviceCard } from '../components/UsbDeviceCard';
import { UsbArcLifecycle } from '../services/UsbArcLifecycle';
import { sharedUsbArcController } from '../services/UsbArcController';
import { UsbDeviceInfo, UsbIpServerStatus } from '../usb/UsbModels';

type UsbArcTab = 'devices' | 'settings';

@Entry
@Component
struct Index {
  @StorageLink('usbArcDevices') private devices: Array<UsbDeviceInfo> = [];
  @StorageLink('usbArcServerStatus') private serverStatus: UsbIpServerStatus = {
    running: false, host: '0.0.0.0', port: 3240, clientCount: 0, sharedDeviceIds: [], lastError: ''
  };
  @StorageLink('usbArcActionMessage') private actionMessage: string = '';
  @State private activeTab: UsbArcTab = 'devices';
  @State private busy: boolean = false;
  @State private wideLayout: boolean = true;
  @State private deviceColumns: number = 2;

  aboutToAppear(): void {
    void sharedUsbArcController.refresh();
  }

  private async toggleServer(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      if (this.serverStatus.running) {
        await sharedUsbArcController.stopServer();
      } else {
        await sharedUsbArcController.startServer();
      }
    } finally {
      this.busy = false;
    }
  }

  private async requestPermission(deviceId: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await sharedUsbArcController.requestPermission(deviceId);
    } finally {
      this.busy = false;
    }
  }

  private async shareDevice(deviceId: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await sharedUsbArcController.shareDevice(deviceId);
    } finally {
      this.busy = false;
    }
  }

  private async unshareDevice(deviceId: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      await sharedUsbArcController.unshareDevice(deviceId);
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
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.busy = false;
      this.getUIContext().getPromptAction().showToast({
        message: `退出时清理失败，code=${businessError.code ?? -1}`
      });
    }
  }

  private selectTab(tab: UsbArcTab): void {
    this.activeTab = tab;
  }

  @Builder
  private Metric(value: string, label: string) {
    Column({ space: 4 }) {
      Text(value).fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary'))
      Text(label).fontSize(12).fontColor($r('sys.color.font_secondary'))
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ right: 28 })
  }

  @Builder
  private HomeContent() {
    Scroll() {
      Column({ space: 20 }) {
        Row({ space: 18 }) {
          Column({ space: 6 }) {
            Text('USB 设备共享')
              .fontSize(32)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
            Text('让局域网中的 USB/IP 客户端访问本机 USB 设备')
              .fontSize(15)
              .fontColor($r('sys.color.font_secondary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Button('刷新设备')
            .enabled(!this.busy)
            .onClick((): void => { void sharedUsbArcController.refresh(); })
        }
        .width('100%')
        .padding({ top: 26, bottom: 4 })

        Column({ space: 20 }) {
          Row({ space: 14 }) {
            Circle()
              .width(12)
              .height(12)
              .fill(this.serverStatus.running ? '#FF42C98A' : '#FF8993A3')
            Column({ space: 5 }) {
              Text(this.serverStatus.running ? 'USB/IP 服务正在运行' : 'USB/IP 服务已停止')
                .fontSize(21)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('sys.color.font_primary'))
              Text(this.serverStatus.running ?
                `监听 ${this.serverStatus.host}:${this.serverStatus.port}` : '启动服务后，已共享设备即可供客户端连接')
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text(this.serverStatus.running ? '运行中' : '已停止')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.serverStatus.running ? '#FF42C98A' : $r('sys.color.font_secondary'))
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .backgroundColor(this.serverStatus.running ? '#2432A978' : $r('sys.color.background_secondary'))
              .borderRadius(20)
            Button(this.serverStatus.running ? '停止服务' : '启动服务')
              .enabled(!this.busy)
              .onClick((): void => { void this.toggleServer(); })
          }
          .width('100%')

          Row({ space: 0 }) {
            this.Metric(`${this.devices.filter((device: UsbDeviceInfo): boolean => device.shared).length}`, '共享设备')
            this.Metric(`${this.serverStatus.clientCount}`, '连接客户端')
            this.Metric(`${this.devices.length}`, '检测设备')
            Text(`地址  ${this.serverStatus.host}:${this.serverStatus.port}`)
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 18 })
          .border({ width: { top: 1 }, color: $r('sys.color.comp_divider') })

          if (this.serverStatus.lastError.length > 0) {
            Text(this.serverStatus.lastError)
              .fontSize(13)
              .fontColor('#FFFF7B72')
              .width('100%')
          } else if (this.serverStatus.running) {
            Text('USB/IP不提供内置认证或加密，请仅在可信网络或现有安全隧道中使用。')
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
          }
        }
        .width('100%')
        .padding(24)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.card_border') })
        .borderRadius(24)

        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('USB 设备')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
            Text('管理授权状态与远程共享')
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text(`${this.devices.length} 台`)
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(16)
        }
        .width('100%')
        .padding({ top: 4 })

        if (this.devices.length === 0) {
          Row({ space: 18 }) {
            Column() {
              Image($r('app.media.usb_device')).width(34).height(34)
            }
            .width(66)
            .height(66)
            .justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.accent_soft'))
            .borderRadius(22)
            Column({ space: 6 }) {
              Text('连接 USB 设备以开始')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
              Text('支持 U 盘、J-Link、ST-Link、USB 转 TTL 与 CDC。设备接入后会显示在这里，授权由系统弹窗确认。')
                .fontSize(14)
                .fontColor($r('sys.color.font_secondary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding(22)
          .backgroundColor($r('app.color.card_background'))
          .border({ width: 1, color: $r('app.color.card_border') })
          .borderRadius(24)
        } else {
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
            ForEach(this.devices, (device: UsbDeviceInfo) => {
              UsbDeviceCard({
                device: device,
                busy: this.busy,
                onPermission: (deviceId: string): void => { void this.requestPermission(deviceId); },
                onShare: (deviceId: string): void => { void this.shareDevice(deviceId); },
                onUnshare: (deviceId: string): void => { void this.unshareDevice(deviceId); }
              })
                .width(this.deviceColumns === 3 ? '31%' : (this.deviceColumns === 2 ? '48%' : '100%'))
                .margin({ right: 12, bottom: 12 })
            }, (device: UsbDeviceInfo): string => device.id)
          }
          .width('100%')
        }

        if (this.actionMessage.length > 0) {
          Text(this.actionMessage)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .padding({ left: 4, right: 4, bottom: 18 })
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 2200 })
      .padding({ left: this.wideLayout ? 42 : 20, right: this.wideLayout ? 42 : 20, bottom: 36 })
      .alignSelf(ItemAlign.Center)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
  }

  @Builder
  private TabItem(tab: UsbArcTab, label: string) {
    Column({ space: 3 }) {
      if (tab === 'devices') {
        Image(this.activeTab === tab ? $r('app.media.tab_devices') : $r('app.media.tab_devices_inactive'))
          .width(24).height(24)
      } else {
        Image(this.activeTab === tab ? $r('app.media.tab_settings') : $r('app.media.tab_settings_inactive'))
          .width(24).height(24)
      }
      Text(label)
        .fontSize(12)
        .fontWeight(this.activeTab === tab ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.activeTab === tab ? '#FF6BA7FF' : $r('sys.color.font_secondary'))
    }
    .width(120)
    .height(58)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.activeTab === tab ? $r('app.color.accent_soft') : Color.Transparent)
    .borderRadius(28)
    .onClick((): void => this.selectTab(tab))
  }

  build() {
    Column() {
      if (this.activeTab === 'devices') {
        this.HomeContent()
      } else {
        UsbArcSettings()
          .layoutWeight(1)
      }

      Row({ space: 8 }) {
        this.TabItem('devices', '设备')
        this.TabItem('settings', '设置')
      }
      .padding(8)
      .backgroundColor($r('app.color.card_background'))
      .border({ width: 1, color: $r('app.color.card_border') })
      .borderRadius(38)
      .shadow({ radius: 20, color: '#33000000', offsetY: 5 })
      .margin({ bottom: 18 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      this.wideLayout = newValue.width >= 1100;
      this.deviceColumns = newValue.width >= 1500 ? 3 : (newValue.width >= 1100 ? 2 : 1);
    })
  }
}
