import { UsbBackendMode, UsbConfigurationInfo, UsbDeviceInfo, UsbInterfaceInfo } from '../usb/UsbModels';

@Component
export struct UsbDeviceCard {
  @Prop device: UsbDeviceInfo;
  @Prop busy: boolean = false;
  @Prop serverRunning: boolean = false;
  @Prop backendMode: UsbBackendMode = 'usbManager';
  onPermission: (deviceId: string) => void = (_deviceId: string): void => {};
  onShare: (deviceId: string) => void = (_deviceId: string): void => {};
  onUnshare: (deviceId: string) => void = (_deviceId: string): void => {};

  private hexId(value: number): string {
    return value.toString(16).padStart(4, '0').toUpperCase();
  }

  private title(): string {
    const product: string = this.device.product.trim();
    if (product.length > 0) return product;
    const name: string = this.device.name.trim();
    if (name.length > 0) return name;
    return `USB ${this.hexId(this.device.vendorId)}:${this.hexId(this.device.productId)}`;
  }

  private statusLabel(): string {
    if (this.device.closing) return '正在释放';
    if (this.device.imported) return '客户端使用中';
    if (this.serverRunning && this.device.shared && this.device.occupied) return '共享中';
    if (this.device.occupied) return '本机占用';
    if (this.serverRunning && this.device.shared) return '等待设备占用';
    return '空闲';
  }

  private deviceIcon(): Resource {
    const hasStorageInterface: boolean = this.device.configurations.some((configuration: UsbConfigurationInfo): boolean =>
      configuration.interfaces.some((usbInterface: UsbInterfaceInfo): boolean => usbInterface.clazz === 8));
    if (this.device.deviceClass === 8 || hasStorageInterface) {
      return $r('app.media.lucide_hard_drive');
    }
    const identity: string = `${this.device.product} ${this.device.name} ${this.device.manufacturer}`.toLowerCase();
    if (identity.includes('sandisk') || identity.includes('flash') || identity.includes('disk') ||
      identity.includes('storage') || identity.includes('mass storage')) {
      return $r('app.media.lucide_hard_drive');
    }
    if (identity.includes('stlink') || identity.includes('st-link') || identity.includes('j-link') ||
      identity.includes('jlink') || identity.includes('debug') || identity.includes('stm32')) {
      return $r('app.media.lucide_cpu');
    }
    if (identity.includes('serial') || identity.includes('uart') || identity.includes('cdc') ||
      identity.includes('cp210') || identity.includes('ch340') || identity.includes('ft232')) {
      return $r('app.media.lucide_cable');
    }
    return $r('app.media.lucide_plug');
  }

  build() {
    Column() {
      Row({ space: 14 }) {
        Column() {
          Image(this.deviceIcon()).width(32).height(32)
        }
        .width(56)
        .height(56)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.accent_soft'))
        .borderRadius(18)
        Column({ space: 4 }) {
          Text(this.title())
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.device.manufacturer.trim().length > 0 ? this.device.manufacturer.trim() : '本机 USB 设备')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Column({ space: 5 }) {
          Text(this.statusLabel())
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.device.closing || this.device.imported ? '#FFFFB86B' :
              (this.serverRunning && this.device.shared && this.device.occupied ? '#FF42C98A' :
                (this.device.occupied ? '#FF68B8FF' : $r('sys.color.font_secondary'))))
            .padding({ left: 9, right: 9, top: 5, bottom: 5 })
            .backgroundColor(this.device.closing || this.device.imported ? '#24F0A33A' :
              (this.serverRunning && this.device.shared && this.device.occupied ? '#2432A978' :
                (this.device.occupied ? '#243D82C4' : $r('sys.color.background_secondary'))))
            .borderRadius(16)
          Text(this.backendMode === 'usbDdk' ?
            (this.device.authorized ? '驱动已连接' : '驱动未连接') :
            (this.device.authorized ? '已授权' : '未授权'))
            .fontSize(10)
            .fontColor(this.device.authorized ? '#FF68B8FF' : $r('sys.color.font_secondary'))
        }
        .width(104)
        .height(50)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .height(56)

      Row({ space: 16 }) {
        Column({ space: 4 }) {
          Text('设备 ID').fontSize(11).fontColor($r('sys.color.font_secondary'))
          Text(`${this.hexId(this.device.vendorId)} : ${this.hexId(this.device.productId)}`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Column({ space: 4 }) {
          Text(this.backendMode === 'usbDdk' ? '逻辑地址' : 'USB 地址')
            .fontSize(11).fontColor($r('sys.color.font_secondary'))
          Text(this.backendMode === 'usbDdk' ? this.device.busId :
            `总线 ${this.device.busNum} · 地址 ${this.device.devAddress}`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height(40)

      Text(this.device.serialNumber.length > 0 ? `序列号 ${this.device.serialNumber}` : ' ')
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .height(18)

      Divider().color($r('sys.color.comp_divider')).height(1)

      Row({ space: 8 }) {
        if (!this.device.authorized) {
          Button(this.busy ? '处理中…' : (this.backendMode === 'usbDdk' ? '连接 USB 驱动' : '请求系统授权'))
            .height(40)
            .enabled(!this.busy && !this.device.closing)
            .onClick((): void => this.onPermission(this.device.id))
        }
        if (this.device.shared) {
          Button(this.busy ? '处理中…' : '停止共享')
            .height(40)
            .enabled(!this.busy && !this.device.closing)
            .onClick((): void => this.onUnshare(this.device.id))
        } else {
          Button(this.busy ? '处理中…' : (this.serverRunning ? '共享设备' : '设为共享'))
            .height(40)
            .enabled(!this.busy && !this.device.closing && !this.device.imported && this.device.authorized)
            .onClick((): void => this.onShare(this.device.id))
        }
      }
      .width('100%')
      .height(42)
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor($r('app.color.card_background'))
    .border({ width: 1, color: $r('app.color.card_border') })
    .borderRadius(24)
  }
}
