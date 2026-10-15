import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DesktopTrayService, sharedDesktopTrayService } from '../services/DesktopTrayService';
import { sharedUsbArcController } from '../services/UsbArcController';

const DOMAIN: number = 0x0000;
const TAG: string = 'UsbArcAbility';

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;
  private readonly trayService: DesktopTrayService = sharedDesktopTrayService;
  private readonly handleWindowWillClose = async (): Promise<boolean> => {
    const mainWindow: window.Window | undefined = this.mainWindow;
    if (mainWindow === undefined || !this.trayService.isRegistered()) {
      return false;
    }
    try {
      await this.context.hideAbility();
      return true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'Unable to hide USBArc. code=%{public}d', businessError.code ?? -1);
      try {
        await mainWindow.minimize();
        return true;
      } catch (fallbackError) {
        const fallback: BusinessError = fallbackError as BusinessError;
        hilog.warn(DOMAIN, TAG, 'Unable to minimize USBArc. code=%{public}d', fallback.code ?? -1);
        return false;
      }
    }
  };

  onCreate(_want: Want, launchParam: AbilityConstant.LaunchParam): void {
    void sharedUsbArcController.initialize(this.context).catch((error: BusinessError): void => {
      hilog.error(DOMAIN, TAG, 'USBArc initialization failed. code=%{public}d', error.code ?? -1);
    });
    hilog.info(DOMAIN, TAG, 'EntryAbility created. reason=%{public}d', launchParam.launchReason);
  }

  onDestroy(): void {
    void sharedUsbArcController.shutdown().catch((error: BusinessError): void => {
      hilog.warn(DOMAIN, TAG, 'USBArc shutdown failed. code=%{public}d', error.code ?? -1);
    });
    this.trayService.dispose(this.context);
    sharedUsbArcController.setTrayRegistered(false);
    hilog.info(DOMAIN, TAG, 'EntryAbility destroyed');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      this.mainWindow = windowStage.getMainWindowSync();
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'Main window unavailable. code=%{public}d', businessError.code ?? -1);
    }
    const mainWindow: window.Window | undefined = this.mainWindow;
    if (mainWindow !== undefined) {
      try {
        mainWindow.on('windowWillClose', this.handleWindowWillClose);
      } catch (error) {
        const businessError: BusinessError = error as BusinessError;
        hilog.info(DOMAIN, TAG, 'Close interception unavailable. code=%{public}d', businessError.code ?? -1);
      }
      this.trayService.register(this.context).then((registered: boolean): void => {
        sharedUsbArcController.setTrayRegistered(registered);
      }).catch((error: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'Status bar registration unavailable. code=%{public}d', error.code ?? -1);
      });
    }
    windowStage.loadContent('pages/Index', (error) => {
      if (error.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load pages/Index. code=%{public}d', error.code);
        return;
      }
      hilog.info(DOMAIN, TAG, 'pages/Index loaded');
    });
  }

  onWindowStageDestroy(): void {
    const mainWindow: window.Window | undefined = this.mainWindow;
    if (mainWindow !== undefined) {
      try {
        mainWindow.off('windowWillClose', this.handleWindowWillClose);
      } catch (error) {
        const businessError: BusinessError = error as BusinessError;
        hilog.warn(DOMAIN, TAG, 'Close listener removal failed. code=%{public}d', businessError.code ?? -1);
      }
    }
    this.mainWindow = undefined;
  }

  onNewWant(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    this.context.showAbility().catch((error: BusinessError): void => {
      hilog.warn(DOMAIN, TAG, 'Unable to restore USBArc. code=%{public}d', error.code ?? -1);
    });
  }

  onForeground(): void {
    void sharedUsbArcController.refresh();
  }
}
