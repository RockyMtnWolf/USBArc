import { UsbDeviceInfo } from '../usb/UsbModels';

@Component
export struct UsbDeviceCard {
  @Prop device: UsbDeviceInfo;
  @Prop busy: boolean = false;
  onPermission: (deviceId: string) => void = (_deviceId: string): void => {};
  onShare: (deviceId: string) => void = (_deviceId: string): void => {};
  onUnshare: (deviceId: string) => void = (_deviceId: string): void => {};

  private hexId(value: number): string {
    return value.toString(16).padStart(4, '0').toUpperCase();
  }

  private title(): string {
    if (this.device.product.length > 0) {
      return this.device.product;
    }
    if (this.device.name.length > 0) {
      return this.device.name;
    }
    return `USB ${this.hexId(this.device.vendorId)}:${this.hexId(this.device.productId)}`;
  }

  build() {
    Column({ space: 16 }) {
      Row({ space: 14 }) {
        Column() {
          Image($r('app.media.usb_device')).width(32).height(32)
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
          Text(this.device.manufacturer.length > 0 ? this.device.manufacturer : '本机 USB 设备')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(this.device.shared ? '共享中' : (this.device.authorized ? '已授权' : '未授权'))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.device.shared ? '#FF42C98A' : (this.device.authorized ? '#FF68B8FF' : $r('sys.color.font_secondary')))
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(this.device.shared ? '#2432A978' : (this.device.authorized ? '#243D82C4' : $r('sys.color.background_secondary')))
          .borderRadius(18)
      }
      Row({ space: 24 }) {
        Column({ space: 4 }) {
          Text('设备 ID').fontSize(11).fontColor($r('sys.color.font_secondary'))
          Text(`${this.hexId(this.device.vendorId)} : ${this.hexId(this.device.productId)}`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
        }
        Column({ space: 4 }) {
          Text('USB 地址').fontSize(11).fontColor($r('sys.color.font_secondary'))
          Text(`总线 ${this.device.busNum}  ·  地址 ${this.device.devAddress}`)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
        }
        if (!this.device.available) {
          Text('当前不可用').fontSize(12).fontColor('#FFFFB86B')
        }
      }
      if (this.device.serialNumber.length > 0) {
        Text(`序列号 ${this.device.serialNumber}`)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Divider().color($r('sys.color.comp_divider'))
      Row({ space: 8 }) {
        Button('请求系统授权')
          .enabled(!this.busy && !this.device.authorized)
          .onClick((): void => this.onPermission(this.device.id))
        if (this.device.shared) {
          Button('停止共享')
            .enabled(!this.busy)
            .onClick((): void => this.onUnshare(this.device.id))
        } else {
          Button('共享设备')
            .enabled(!this.busy && this.device.authorized && this.device.available)
            .onClick((): void => this.onShare(this.device.id))
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.card_background'))
    .border({ width: 1, color: $r('app.color.card_border') })
    .borderRadius(24)
  }
}
