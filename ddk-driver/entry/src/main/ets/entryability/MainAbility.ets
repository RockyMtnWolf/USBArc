import { UIAbility } from '@kit.AbilityKit';

export default class MainAbility extends UIAbility {
  onCreate(): void {
    // The standalone package exists to register its USB DriverExtensionAbility.
  }
}
