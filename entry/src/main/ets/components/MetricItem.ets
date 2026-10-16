@Component
export struct MetricItem {
  @Prop value: string = '';
  @Prop label: string = '';

  build() {
    Column({ space: 4 }) {
      Text(this.value).fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('sys.color.font_primary'))
      Text(this.label).fontSize(12).fontColor($r('sys.color.font_secondary'))
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }
}
