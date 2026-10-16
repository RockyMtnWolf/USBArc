import { UsbArcPreferences, UsbArcPreferencesData, UsbAutoShareRule } from './UsbArcPreferences';
import { UsbDeviceInfo } from '../usb/UsbModels';

export class UsbArcDevicePolicy {
  private attachedIds: Set<string> = new Set<string>();
  private permissionAttemptedIds: Set<string> = new Set<string>();

  updateAttachment(devices: Array<UsbDeviceInfo>): Set<string> {
    const currentIds: Set<string> = new Set<string>();
    devices.forEach((device: UsbDeviceInfo): void => {
      currentIds.add(device.id);
    });
    this.attachedIds.forEach((id: string): void => {
      if (!currentIds.has(id)) {
        this.permissionAttemptedIds.delete(id);
      }
    });
    const arrivedIds: Set<string> = new Set<string>();
    currentIds.forEach((id: string): void => {
      if (!this.attachedIds.has(id)) {
        arrivedIds.add(id);
      }
    });
    this.attachedIds = currentIds;
    return arrivedIds;
  }

  currentAttachmentIds(): Set<string> {
    return new Set<string>(this.attachedIds);
  }

  markPermissionAttempted(deviceId: string): void {
    this.permissionAttemptedIds.add(deviceId);
  }

  resetPermissionAttempt(deviceId: string): void {
    this.permissionAttemptedIds.delete(deviceId);
  }

  shouldRequestPermission(deviceId: string, enabled: boolean, authorized: boolean): boolean {
    if (!enabled || authorized || this.permissionAttemptedIds.has(deviceId)) {
      return false;
    }
    this.permissionAttemptedIds.add(deviceId);
    return true;
  }

  matchesAutoShare(settings: UsbArcPreferencesData, device: UsbDeviceInfo): boolean {
    if (settings.autoShareScope === 'all') {
      return true;
    }
    return settings.rules.some((rule: UsbAutoShareRule): boolean =>
      UsbArcPreferences.ruleMatches(rule, device.vendorId, device.productId, device.serialNumber));
  }

  canManuallyShare(device: UsbDeviceInfo): boolean {
    return device.authorized && device.available && !device.shared;
  }
}
