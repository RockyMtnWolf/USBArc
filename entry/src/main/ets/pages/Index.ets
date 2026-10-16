import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import {
  DividerMode,
  HdsTabs,
  HdsTabsAttribute,
  HdsTabsController,
  hdsMaterial
} from '@kit.UIDesignKit';
import { UsbArcSettings } from '../components/UsbArcSettings';
import { UsbDeviceCard } from '../components/UsbDeviceCard';
import { MetricItem } from '../components/MetricItem';
import { sharedUsbArcController } from '../services/UsbArcController';
import { UsbArcPreferencesData } from '../services/UsbArcPreferences';
import {
  addressMatchesListener,
  NetworkAddressSnapshot,
  NetworkInterfaceAddress,
  selectDisplayNetworkAddresses,
  sharedLocalNetworkAddresses
} from '../services/LocalNetworkAddresses';
import { UsbDeviceInfo, UsbIpServerStatus } from '../usb/UsbModels';

type UsbArcTab = 'devices' | 'settings';
interface NetworkAddressGroupOptions {
  family: 'IPv4' | 'IPv6';
  title: string;
}
const IPV4_NETWORK_GROUP_OPTIONS: NetworkAddressGroupOptions = { family: 'IPv4', title: 'IPv4 地址' };
const IPV6_NETWORK_GROUP_OPTIONS: NetworkAddressGroupOptions = { family: 'IPv6', title: 'IPv6 地址' };

@Entry
@Component
struct Index {
  @StorageLink('usbArcPreferences') private preferences: UsbArcPreferencesData = {
    backendMode: 'usbManager',
    host: '0.0.0.0', port: 3240, autoRequestPermission: false, autoShare: false,
    autoShareScope: 'all', maxClients: 4, forceClaim: false, retainClaimsOnStop: false, backgroundTaskMode: 'off',
    themeMode: 'system', tabBarStyle: 'material', tabBarImagePath: '', appBackgroundEnabled: false, rules: []
  };
  @StorageLink('usbArcDevices') private devices: Array<UsbDeviceInfo> = [];
  @StorageLink('usbArcServerStatus') private serverStatus: UsbIpServerStatus = {
    running: false, host: '0.0.0.0', port: 3240, clientCount: 0,
    sharedDeviceIds: [], occupiedDeviceIds: [], listenerFamilies: [], lastError: ''
  };
  @StorageLink('usbArcActionMessage') private actionMessage: string = '';
  @State private activeTab: UsbArcTab = 'devices';
  @State private serverActionPending: boolean = false;
  @State private startNoticeOpen: boolean = false;
  @State private refreshingDevices: boolean = false;
  @State private pendingDeviceIds: Array<string> = [];
  @State private wideLayout: boolean = true;
  @State private deviceColumns: number = 2;
  @State private layoutWidth: number = 0;
  @State private networkAddresses: Array<NetworkInterfaceAddress> = [];
  @State private networkRefreshing: boolean = false;
  @State private networkEnumerationWarning: string = '';
  private tabsController: HdsTabsController = new HdsTabsController();
  private unsubscribeNetworkAddresses: (() => void) | undefined = undefined;

  aboutToAppear(): void {
    void sharedUsbArcController.refresh();
    this.unsubscribeNetworkAddresses = sharedLocalNetworkAddresses.subscribe((snapshot: NetworkAddressSnapshot): void => {
      this.applyNetworkSnapshot(snapshot);
    });
    void this.refreshNetworkAddresses();
  }

  aboutToDisappear(): void {
    if (this.unsubscribeNetworkAddresses !== undefined) {
      this.unsubscribeNetworkAddresses();
      this.unsubscribeNetworkAddresses = undefined;
    }
  }

  private async refreshNetworkAddresses(): Promise<void> {
    if (this.networkRefreshing) {
      return;
    }
    this.networkRefreshing = true;
    try {
      const snapshot: NetworkAddressSnapshot = await sharedLocalNetworkAddresses.listAddresses();
      this.applyNetworkSnapshot(snapshot);
    } catch (_error) {
      this.networkEnumerationWarning = '网络接口信息读取失败，地址列表可能不完整。';
      this.getUIContext().getPromptAction().showToast({ message: '读取本机网络地址失败。' });
    } finally {
      this.networkRefreshing = false;
    }
  }

  private actionErrorMessage(fallback: string): string {
    const message: string = this.actionMessage;
    if (message.indexOf('失败') >= 0 || message.indexOf('未完成') >= 0 ||
      message.indexOf('未获得') >= 0 || message.indexOf('不可用') >= 0 ||
      message.indexOf('无法') >= 0 || message.indexOf('拒绝') >= 0) {
      return message;
    }
    return fallback;
  }

  private addPendingDevice(deviceId: string): boolean {
    if (this.pendingDeviceIds.includes(deviceId)) return false;
    this.pendingDeviceIds = this.pendingDeviceIds.concat([deviceId]);
    return true;
  }

  private removePendingDevice(deviceId: string): void {
    this.pendingDeviceIds = this.pendingDeviceIds.filter((item: string): boolean => item !== deviceId);
  }

  private async refreshDevices(): Promise<void> {
    if (this.refreshingDevices) return;
    this.refreshingDevices = true;
    try {
      await sharedUsbArcController.refresh();
    } finally {
      this.refreshingDevices = false;
    }
  }

  private applyNetworkSnapshot(snapshot: NetworkAddressSnapshot): void {
    this.networkAddresses = selectDisplayNetworkAddresses(snapshot.addresses, snapshot.activeInterfaceNames);
    const failures: Array<string> = snapshot.limitations.filter((limitation: string): boolean =>
      limitation.indexOf('失败') >= 0);
    this.networkEnumerationWarning = failures.length > 0 ? '部分网卡信息未能读取，地址列表可能不完整。' : '';
  }

  private connectionAddress(address: NetworkInterfaceAddress): string {
    if (address.family === 'IPv6') {
      return `[${address.address}]:${this.serverStatus.port}`;
    }
    return `${address.address}:${this.serverStatus.port}`;
  }

  private addressNote(address: NetworkInterfaceAddress): string {
    if (address.isLoopback) return '仅本机';
    if (addressMatchesListener(address, this.serverStatus)) return '监听中';
    if (!this.serverStatus.running) return '服务启动后确认';
    return '未被监听';
  }

  private async copyNetworkAddress(address: NetworkInterfaceAddress): Promise<void> {
    const value: string = addressMatchesListener(address, this.serverStatus) ? this.connectionAddress(address) : address.address;
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value);
      await pasteboard.getSystemPasteboard().setData(data);
      this.getUIContext().getPromptAction().showToast({ message: addressMatchesListener(address, this.serverStatus) ? '连接端点已复制' : 'IP地址已复制' });
    } catch (_error) {
      this.getUIContext().getPromptAction().showToast({ message: '复制地址失败。' });
    }
  }

  @Builder
  private NetworkAddressItem(address: NetworkInterfaceAddress) {
    Row({ space: 10 }) {
      Column({ space: 5 }) {
        Row({ space: 8 }) {
          Text(`${address.interfaceName}  /${address.prefixLength}`)
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_secondary'))
          if (this.addressNote(address).length > 0) {
            Text(this.addressNote(address))
              .fontSize(10)
              .fontColor($r('sys.color.font_secondary'))
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor($r('app.color.card_background'))
              .borderRadius(8)
          }
        }
        .width('100%')
        Text(addressMatchesListener(address, this.serverStatus) ?
          this.connectionAddress(address) : address.address)
          .fontSize(14)
          .fontColor(addressMatchesListener(address, this.serverStatus) ? $r('app.color.accent') : $r('sys.color.font_primary'))
          .wordBreak(WordBreak.BREAK_ALL)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button(addressMatchesListener(address, this.serverStatus) ? '复制端点' : '复制 IP')
        .fontSize(12)
        .padding({ left: 8, right: 8 })
        .onClick((): void => { void this.copyNetworkAddress(address); })
    }
    .width('100%')
    .padding({ top: 9, bottom: 9, left: 10, right: 10 })
    .backgroundColor($r('app.color.page_background'))
    .borderRadius(12)
  }

  @Builder
  private NetworkAddressGroup(options: NetworkAddressGroupOptions) {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(options.title).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
        Text(`${this.networkAddresses.filter((item: NetworkInterfaceAddress): boolean => item.family === options.family).length}`)
          .fontSize(11).fontColor($r('sys.color.font_secondary'))
        if (this.serverStatus.running && this.serverStatus.listenerFamilies.includes(options.family)) {
          Text('正在监听')
            .fontSize(10)
            .fontColor($r('app.color.accent'))
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      if (this.networkAddresses.filter((item: NetworkInterfaceAddress): boolean => item.family === options.family).length === 0) {
        Text(this.networkRefreshing ? `正在读取 ${options.family} 地址…` : `未获取到 ${options.family} 地址`)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .padding({ top: 4, bottom: 4 })
      } else {
        Column({ space: 6 }) {
          ForEach(this.networkAddresses.filter((item: NetworkInterfaceAddress): boolean => item.family === options.family),
            (item: NetworkInterfaceAddress) => {
              Column() {
                this.NetworkAddressItem(item)
              }
                .width('100%')
            }, (item: NetworkInterfaceAddress): string =>
              `${item.key}|${this.serverStatus.running}|${this.serverStatus.host}|${this.serverStatus.port}|${this.serverStatus.listenerFamilies.join(',')}`)
        }
        .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private async toggleServer(): Promise<void> {
    if (this.serverActionPending) return;
    if (!this.serverStatus.running) {
      this.confirmStartServer();
      return;
    }
    await this.performServerAction(false);
  }

  private confirmStartServer(): void {
    if (this.startNoticeOpen) return;
    this.startNoticeOpen = true;
    this.getUIContext().showAlertDialog({
      title: '允许 USBArc 接收入站连接？',
      message: `将监听 TCP ${this.preferences.port}（${this.plannedListenerFamily()}）。通过 MeshArc 连接时，请在 MeshArc 放行此端口。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: (): void => { this.startNoticeOpen = false; }
      },
      secondaryButton: {
        value: '允许并启动',
        action: (): void => {
          this.startNoticeOpen = false;
          void this.performServerAction(true);
        }
      },
      cancel: (): void => { this.startNoticeOpen = false; }
    });
  }

  private async performServerAction(start: boolean): Promise<void> {
    if (this.serverActionPending) return;
    this.serverActionPending = true;
    try {
      const succeeded: boolean = start ? await sharedUsbArcController.startServer() :
        await sharedUsbArcController.stopServer();
      if (!succeeded) {
        this.getUIContext().getPromptAction().showToast({ message: this.actionErrorMessage(start ? 'USB/IP 服务启动失败。' : '停止 USB/IP 服务失败。') });
      }
    } finally {
      this.serverActionPending = false;
    }
  }

  private async requestPermission(deviceId: string): Promise<void> {
    if (!this.addPendingDevice(deviceId)) return;
    try {
      const granted: boolean = await sharedUsbArcController.requestPermission(deviceId);
      if (!granted) {
        const fallback: string = this.preferences.backendMode === 'usbDdk' ?
          'USB 驱动未能连接或初始化。' : '尚未获得 USB 授权，请完成系统确认。';
        this.getUIContext().getPromptAction().showToast({ message: this.actionErrorMessage(fallback) });
      }
    } finally {
      this.removePendingDevice(deviceId);
    }
  }

  private async shareDevice(deviceId: string): Promise<void> {
    if (!this.addPendingDevice(deviceId)) return;
    try {
      const shared: boolean = await sharedUsbArcController.shareDevice(deviceId);
      if (!shared) {
        this.getUIContext().getPromptAction().showToast({ message: this.actionErrorMessage('共享设备失败。') });
      }
    } finally {
      this.removePendingDevice(deviceId);
    }
  }

  private async unshareDevice(deviceId: string): Promise<void> {
    if (!this.addPendingDevice(deviceId)) return;
    try {
      const unshared: boolean = await sharedUsbArcController.unshareDevice(deviceId);
      if (!unshared) {
        this.getUIContext().getPromptAction().showToast({ message: this.actionErrorMessage('停止共享失败。') });
      }
    } finally {
      this.removePendingDevice(deviceId);
    }
  }

  private tabBarWidth(): number {
    return Math.min(Math.max(0, this.layoutWidth - 32), this.layoutWidth < 600 ? 520 : 800);
  }

  private plannedListenerFamily(): string {
    const host: string = this.preferences.host.trim();
    if (host.length === 0 || host === '0.0.0.0' || host === '::') return 'IPv4 / IPv6';
    return host.includes(':') ? 'IPv6' : 'IPv4';
  }

  private hasTabBarImage(): boolean {
    if (this.preferences.tabBarImagePath.length === 0) {
      return false;
    }
    try {
      return fileIo.accessSync(this.preferences.tabBarImagePath);
    } catch (_error) {
      return false;
    }
  }

  @Builder
  private HomeContent() {
    Scroll() {
      Column({ space: 20 }) {
        Row({ space: 18 }) {
          Column({ space: 6 }) {
            Text('USB 设备共享')
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
            Text('让局域网中的 USB/IP 客户端访问本机 USB 设备')
              .fontSize(15)
              .fontColor($r('sys.color.font_secondary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Button('刷新设备')
            .onClick((): void => { void this.refreshDevices(); })
        }
        .width('100%')
        .padding({ top: 26, bottom: 4 })

        Column({ space: 12 }) {
          Row({ space: 14 }) {
            Row({ space: 10 }) {
              Circle()
                .width(10)
                .height(10)
                .fill(this.serverStatus.running ? '#FF42C98A' : '#FF8993A3')
              Column({ space: 4 }) {
                Text(this.serverStatus.running ? 'USB/IP 服务正在运行' : 'USB/IP 服务已停止')
                  .fontSize(18)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.font_primary'))
                Text(this.serverStatus.running ? '局域网客户端可连接本机共享设备' : '启动服务后，已共享设备即可供客户端访问')
                  .fontSize(13)
                  .fontColor($r('sys.color.font_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .layoutWeight(1)
            .height(54)
            .alignItems(VerticalAlign.Center)

            Button(this.serverActionPending ? '正在处理…' : (this.serverStatus.running ? '停止服务' : '启动服务'))
              .onClick((): void => { void this.toggleServer(); })
          }
          .width('100%')

          Row({ space: 10 }) {
            MetricItem({
              value: `${this.serverStatus.running ? this.serverStatus.sharedDeviceIds.length : 0}`,
              label: '共享设备'
            })
            MetricItem({ value: `${this.serverStatus.clientCount}`, label: '连接客户端' })
            MetricItem({ value: `${this.devices.length}`, label: '检测设备' })
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 8, bottom: 8 })
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .borderRadius(14)

          Row({ space: 6 }) {
            Text('监听配置')
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
            Text(`${this.serverStatus.host === '0.0.0.0' || this.serverStatus.host === '::' ? '所有网络接口' : this.serverStatus.host}  ·  端口 ${this.serverStatus.port}`)
              .fontSize(12)
              .fontColor($r('sys.color.font_primary'))
          }
          .width('100%')

          if (this.serverStatus.lastError.length > 0) {
            Text(this.serverStatus.lastError)
              .fontSize(13)
              .fontColor('#FFFF7B72')
              .width('100%')
          }
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.card_border') })
        .borderRadius(24)

        Column({ space: 12 }) {
          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text(this.networkAddresses.length > 0 ?
                `${this.networkAddresses[0].interfaceName} 网络地址` : '当前网络地址')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Button(this.networkRefreshing ? '刷新中…' : '刷新地址')
              .enabled(!this.networkRefreshing)
              .onClick((): void => { void this.refreshNetworkAddresses(); })
          }
          .width('100%')
          if (this.wideLayout) {
            Row({ space: 16 }) {
              Column() {
                this.NetworkAddressGroup(IPV4_NETWORK_GROUP_OPTIONS)
              }
              .layoutWeight(1)
              Column() {
                this.NetworkAddressGroup(IPV6_NETWORK_GROUP_OPTIONS)
              }
              .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          } else {
            this.NetworkAddressGroup(IPV4_NETWORK_GROUP_OPTIONS)
            this.NetworkAddressGroup(IPV6_NETWORK_GROUP_OPTIONS)
          }
          if (this.networkEnumerationWarning.length > 0) {
            Text(this.networkEnumerationWarning)
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
          }
        }
        .width('100%')
        .padding(20)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.card_background'))
        .border({ width: 1, color: $r('app.color.card_border') })
        .borderRadius(22)

        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('USB 设备')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.font_primary'))
            Text(this.preferences.backendMode === 'usbDdk' ? '管理驱动连接与远程共享' : '管理授权状态与远程共享')
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
              Text(this.preferences.backendMode === 'usbDdk' ?
                '设备接入后先显示为未连接；连接成功需驱动完成初始化和设备匹配。' :
                '支持 U 盘、J-Link、ST-Link、USB 转 TTL 与 CDC。设备接入后会显示在这里，授权由系统弹窗确认。')
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
          Grid() {
            ForEach(this.devices, (device: UsbDeviceInfo) => {
              GridItem() {
                UsbDeviceCard({
                  device: device,
                  serverRunning: this.serverStatus.running,
                  backendMode: this.preferences.backendMode,
                  busy: this.pendingDeviceIds.includes(device.id),
                  onPermission: (deviceId: string): void => { void this.requestPermission(deviceId); },
                  onShare: (deviceId: string): void => { void this.shareDevice(deviceId); },
                  onUnshare: (deviceId: string): void => { void this.unshareDevice(deviceId); }
                })
              }.height(286)
            }, (device: UsbDeviceInfo): string =>
              `${device.id}|${device.authorized}|${device.shared}|${device.occupied}|${device.imported}|${device.closing}|${device.available}|${device.product}|${device.name}|${device.manufacturer}|${device.serialNumber}|${this.serverStatus.running}|${this.pendingDeviceIds.includes(device.id)}`)
          }
          .columnsTemplate(this.deviceColumns === 3 ? '1fr 1fr 1fr' : (this.deviceColumns === 2 ? '1fr 1fr' : '1fr'))
          .columnsGap(12)
          .rowsGap(12)
          .width('100%')
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 2200 })
      .padding({ left: this.wideLayout ? 42 : 20, right: this.wideLayout ? 42 : 20, bottom: 100 })
      .alignSelf(ItemAlign.Center)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
  }

  build() {
    Stack() {
      if (this.preferences.appBackgroundEnabled && this.hasTabBarImage()) {
        Image(fileUri.getUriFromPath(this.preferences.tabBarImagePath))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .opacity(0.42)
          .hitTestBehavior(HitTestMode.None)
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.app_background_tint'))
          .hitTestBehavior(HitTestMode.None)
      }
      HdsTabs({
        barPosition: BarPosition.End,
        index: this.activeTab === 'devices' ? 0 : 1,
        controller: this.tabsController
      }) {
        TabContent() {
          this.HomeContent()
        }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.externaldrive'))
              .fontSize(24).fontColor([$r('sys.color.font_secondary')]),
            selected: new SymbolGlyphModifier($r('sys.symbol.externaldrive'))
              .fontSize(24).fontColor([$r('app.color.accent')])
          }, '设备')
            .id('tab-devices')
            .labelStyle({
              unselectedColor: $r('sys.color.font_secondary'),
              selectedColor: $r('app.color.accent')
            })
            .iconStyle({
              unselectedColor: $r('sys.color.font_secondary'),
              selectedColor: $r('app.color.accent')
            }))
        TabContent() {
          UsbArcSettings()
        }
          .tabBar(new BottomTabBarStyle({
            normal: new SymbolGlyphModifier($r('sys.symbol.gearshape'))
              .fontSize(24).fontColor([$r('sys.color.font_secondary')]),
            selected: new SymbolGlyphModifier($r('sys.symbol.gearshape'))
              .fontSize(24).fontColor([$r('app.color.accent')])
          }, '设置')
            .id('tab-settings')
            .labelStyle({
              unselectedColor: $r('sys.color.font_secondary'),
              selectedColor: $r('app.color.accent')
            })
            .iconStyle({
              unselectedColor: $r('sys.color.font_secondary'),
              selectedColor: $r('app.color.accent')
            }))
      }
      .vertical(false)
      .scrollable(true)
      .animationDuration(250)
      .barMode(BarMode.Fixed)
      .barWidth(this.tabBarWidth())
      .barHeight(56)
      .barOverlap(true)
      .barBackgroundColor(Color.Transparent)
      .barFloatingStyle({
        barSideMargin: 16,
        barBottomMargin: 18,
        gradientMask: {
          maskColor: $r('app.color.page_background'),
          maskHeight: 90
        },
        lightColor: $r('app.color.accent'),
        barOpacity: 0.96,
        thermoCtrl: true,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      })
      .divider({ mode: DividerMode.NONE })
      .onChange((index: number): void => {
        this.activeTab = index === 0 ? 'devices' : 'settings';
      })
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .onAreaChange((_oldValue: Area, newValue: Area): void => {
      this.layoutWidth = Number(newValue.width);
      this.wideLayout = newValue.width >= 1100;
      this.deviceColumns = newValue.width >= 1500 ? 3 : (newValue.width >= 1100 ? 2 : 1);
    })
  }
}
