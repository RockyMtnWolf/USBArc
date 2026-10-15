import { UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { StatusBarViewExtensionAbility } from '@kit.DeskTopExtensionKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'UsbArcStatusBar';

export default class UsbArcStatusBarAbility extends StatusBarViewExtensionAbility {
  onSessionCreate(_want: Want, session: UIExtensionContentSession): void {
    try {
      session.loadContent('pages/StatusBarPage');
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'Status bar quick operation page failed. code=%{public}d',
        businessError.code ?? -1);
    }
  }
}
