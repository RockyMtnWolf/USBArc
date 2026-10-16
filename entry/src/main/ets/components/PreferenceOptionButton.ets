@Component
export struct PreferenceOptionButton {
  @Prop title: string = '';
  @Prop selected: boolean = false;
  @Prop isEnabled: boolean = true;
  onSelected: () => void = (): void => {};

  build() {
    Button(this.selected ? `●  ${this.title}` : `○  ${this.title}`)
      .layoutWeight(1)
      .height(40)
      .enabled(this.isEnabled)
      .fontColor(this.selected ? $r('app.color.accent') : $r('sys.color.font_primary'))
      .backgroundColor(this.selected ? $r('app.color.accent_soft') : $r('app.color.card_background'))
      .border({ width: 1, color: this.selected ? $r('app.color.accent') : $r('app.color.card_border') })
      .onClick((): void => this.onSelected())
  }
}
