import { common } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { statusBarManager } from '@kit.DeskTopExtensionKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'UsbArcTray';

export class DesktopTrayService {
  private registering: boolean = false;
  private registered: boolean = false;
  private disposed: boolean = false;
  private lifecycleGeneration: number = 0;
  private pendingRegistration?: Promise<boolean>;
  private whiteIcon?: image.PixelMap;
  private blackIcon?: image.PixelMap;

  isRegistered(): boolean {
    return this.registered && !this.disposed;
  }

  async register(context: common.UIAbilityContext): Promise<boolean> {
    if (this.disposed) {
      this.disposed = false;
      this.lifecycleGeneration++;
    }
    if (this.registered) {
      return true;
    }
    if (this.pendingRegistration !== undefined) {
      await this.pendingRegistration;
      return this.registered && !this.disposed ? true : await this.register(context);
    }
    this.registering = true;
    const generation: number = this.lifecycleGeneration;
    const pending: Promise<boolean> = this.registerStatusBar(context, generation).then((): boolean => this.isRegistered());
    this.pendingRegistration = pending;
    try {
      return await pending;
    } finally {
      this.registering = false;
      if (this.pendingRegistration === pending) {
        this.pendingRegistration = undefined;
      }
      if (!this.registered && !this.disposed && generation !== this.lifecycleGeneration) {
        void this.register(context);
      }
    }
  }

  dispose(context: common.UIAbilityContext): void {
    this.disposed = true;
    this.lifecycleGeneration++;
    if (this.registered) {
      try {
        statusBarManager.removeFromStatusBar(context);
      } catch (error) {
        const businessError: BusinessError = error as BusinessError;
        hilog.warn(DOMAIN, TAG, 'Status bar removal failed. code=%{public}d', businessError.code ?? -1);
      }
      this.registered = false;
    }
    this.releaseIcon(this.whiteIcon);
    this.releaseIcon(this.blackIcon);
    this.whiteIcon = undefined;
    this.blackIcon = undefined;
  }

  private async registerStatusBar(context: common.UIAbilityContext, generation: number): Promise<void> {
    let whiteIcon: image.PixelMap | undefined;
    let blackIcon: image.PixelMap | undefined;
    try {
      if (deviceInfo.sdkApiVersion < 26 || deviceInfo.deviceType !== deviceInfo.DeviceTypes.TYPE_2IN1 ||
        typeof statusBarManager.isStatusBarCapabilitySupported !== 'function' ||
        !await statusBarManager.isStatusBarCapabilitySupported(context)) {
        return;
      }
      whiteIcon = await this.createIcon(context, 'usbarc_status_white.svg');
      blackIcon = await this.createIcon(context, 'usbarc_status_black.svg');
      if (this.disposed || generation !== this.lifecycleGeneration) {
        return;
      }
      const item: statusBarManager.StatusBarItem = {
        icons: { white: whiteIcon, black: blackIcon },
        quickOperation: {
          abilityName: 'UsbArcStatusBarAbility',
          moduleName: 'entry',
          title: 'USBArc',
          height: 120
        },
        statusBarGroupMenu: [[{
          title: '打开 USBArc',
          menuAction: { abilityName: 'EntryAbility', moduleName: 'entry' }
        }]],
        hoverTips: 'USBArc'
      };
      statusBarManager.addToStatusBar(context, item);
      this.whiteIcon = whiteIcon;
      this.blackIcon = blackIcon;
      whiteIcon = undefined;
      blackIcon = undefined;
      this.registered = true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'Status bar registration unavailable. code=%{public}d', businessError.code ?? -1);
    } finally {
      this.releaseIcon(whiteIcon);
      this.releaseIcon(blackIcon);
    }
  }

  private async createIcon(context: common.UIAbilityContext, fileName: string): Promise<image.PixelMap> {
    const rawFile = context.resourceManager.getRawFileContentSync(fileName);
    const source: image.ImageSource = image.createImageSource(rawFile.buffer);
    try {
      return await source.createPixelMap();
    } finally {
      await source.release();
    }
  }

  private releaseIcon(icon?: image.PixelMap): void {
    if (icon !== undefined) {
      icon.release().catch((error: BusinessError): void => {
        hilog.warn(DOMAIN, TAG, 'Status bar icon release failed. code=%{public}d', error.code ?? -1);
      });
    }
  }
}

export const sharedDesktopTrayService: DesktopTrayService = new DesktopTrayService();
