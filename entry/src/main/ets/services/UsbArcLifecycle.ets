import { common } from '@kit.AbilityKit';
import { sharedDesktopTrayService } from './DesktopTrayService';
import { sharedUsbArcController } from './UsbArcController';

export class UsbArcLifecycle {
  static async exit(context: common.UIAbilityContext): Promise<void> {
    try {
      await sharedUsbArcController.shutdown();
    } finally {
      sharedDesktopTrayService.dispose(context);
      await context.terminateSelf();
    }
  }
}
