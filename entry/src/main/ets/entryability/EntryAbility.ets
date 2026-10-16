import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DesktopTrayService, sharedDesktopTrayService } from '../services/DesktopTrayService';
import { UsbArcLifecycle } from '../services/UsbArcLifecycle';
import { sharedUsbArcController } from '../services/UsbArcController';
import { UsbArcThemeController } from '../services/UsbArcThemeController';

const DOMAIN: number = 0x0000;
const TAG: string = 'UsbArcAbility';

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;
  private readonly trayService: DesktopTrayService = sharedDesktopTrayService;
  private initialization: Promise<void> = Promise.resolve();
  private exitRequested: boolean = false;
  private exitStarted: boolean = false;
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

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.exitRequested = this.isExitAction(want);
    this.initialization = sharedUsbArcController.initialize(this.context);
    this.initialization.catch((error: BusinessError): void => {
      hilog.error(DOMAIN, TAG, 'USBArc initialization failed. code=%{public}d', error.code ?? -1);
    });
    if (this.exitRequested) void this.exitApplication();
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
    if (this.exitRequested) return;
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
      this.trayService.register(this.context, (): void => {
        this.exitRequested = true;
        void this.exitApplication();
      }).then((registered: boolean): void => {
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
      this.initialization.then((): void => {
        UsbArcThemeController.apply(this.context, sharedUsbArcController.getPreferences().themeMode);
      }, (initializationError: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'Unable to restore app theme. code=%{public}d', initializationError.code ?? -1);
      });
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

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    if (this.isExitAction(want)) {
      this.exitRequested = true;
      void this.exitApplication();
      return;
    }
    this.context.showAbility().catch((error: BusinessError): void => {
      hilog.warn(DOMAIN, TAG, 'Unable to restore USBArc. code=%{public}d', error.code ?? -1);
    });
  }

  onForeground(): void {
    if (!this.exitRequested) void sharedUsbArcController.refresh();
  }

  private isExitAction(want: Want): boolean {
    return want.parameters?.['desktopTrayAction'] === 'exit';
  }

  private async exitApplication(): Promise<void> {
    if (this.exitStarted) return;
    this.exitStarted = true;
    try {
      await this.initialization;
    } catch (_error) {
      // Continue teardown even if startup failed partway through.
    }
    try {
      await UsbArcLifecycle.exit(this.context);
    } catch (error) {
      this.exitStarted = false;
      const businessError: BusinessError = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'USBArc exit failed. code=%{public}d', businessError.code ?? -1);
    }
  }
}
