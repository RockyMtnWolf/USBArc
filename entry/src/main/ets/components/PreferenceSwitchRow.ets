@Component
export struct PreferenceSwitchRow {
  @Prop title: string = '';
  @Prop description: string = '';
  @Prop checked: boolean = false;
  @Prop pending: boolean = false;
  @Prop toggleEnabled: boolean = true;
  onChange: (value: boolean) => void = (_value: boolean): void => {};

  build() {
    Row({ space: 14 }) {
      Column({ space: 5 }) {
        Text(this.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
        if (this.description.length > 0) {
          Text(this.description).fontSize(12).fontColor($r('sys.color.font_secondary'))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.pending) {
        LoadingProgress().width(18).height(18)
      }
      Toggle({ type: ToggleType.Switch, isOn: this.checked })
        .enabled(this.toggleEnabled)
        .onChange((value: boolean): void => this.onChange(value))
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }
}
