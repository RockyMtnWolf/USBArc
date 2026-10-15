import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'UsbArcStatusPage';

@Entry
@Component
struct StatusBarPage {
  private openApplication(): void {
    const context = this.getUIContext().getHostContext() as common.UIExtensionContext | undefined;
    if (context === undefined) {
      return;
    }
    context.startAbility({
      bundleName: 'io.github.rockymtnwolf.usbarc',
      abilityName: 'EntryAbility',
      parameters: { desktopTrayAction: 'open' }
    }).catch((error: BusinessError): void => {
      hilog.warn(DOMAIN, TAG, 'Unable to open USBArc. code=%{public}d', error.code ?? -1);
    });
  }

  build() {
    Column({ space: 16 }) {
      Text('USBArc')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
      Button('打开 USBArc')
        .onClick((): void => this.openApplication())
    }
    .width('100%')
    .height('100%')
    .padding(20)
  }
}
