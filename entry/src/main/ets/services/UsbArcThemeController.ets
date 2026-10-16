import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { UsbArcThemeMode } from './UsbArcPreferences';

export class UsbArcThemeController {
  static apply(context: common.UIAbilityContext, mode: UsbArcThemeMode): void {
    let colorMode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === 'light') {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (mode === 'dark') {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    context.setColorMode(colorMode);
  }
}
