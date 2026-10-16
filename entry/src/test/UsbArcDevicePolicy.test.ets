import { describe, it, expect } from '@ohos/hypium';
import { UsbArcDevicePolicy } from '../main/ets/services/UsbArcDevicePolicy';
import { UsbArcPreferencesData } from '../main/ets/services/UsbArcPreferences';
import { UsbDeviceInfo } from '../main/ets/usb/UsbModels';

function fixtureDevice(id: string): UsbDeviceInfo {
  return {
    id,
    name: 'Test USB device',
    path: '/sys/devices/usb/1-2',
    busId: '1-2',
    busNum: 1,
    devAddress: 2,
    vendorId: 0x1234,
    productId: 0xabcd,
    speed: 0,
    manufacturer: 'Fixture',
    product: 'Test USB device',
    serialNumber: '',
    version: '1.0',
    deviceClass: 0,
    deviceSubClass: 0,
    deviceProtocol: 0,
    configurations: [],
    authorized: true,
    occupied: false,
    shared: false,
    imported: false,
    closing: false,
    available: true
  };
}

function preferences(): UsbArcPreferencesData {
  return {
    backendMode: 'usbManager',
    host: '0.0.0.0',
    port: 3240,
    autoRequestPermission: false,
    autoShare: false,
    autoShareScope: 'all',
    maxClients: 4,
    forceClaim: false,
    retainClaimsOnStop: false,
    backgroundTaskMode: 'off',
    themeMode: 'system',
    tabBarStyle: 'material',
    tabBarImagePath: '',
    appBackgroundEnabled: false,
    rules: []
  };
}

export default function UsbArcDevicePolicyTest() {
  describe('UsbArcDevicePolicyTest', () => {
    it('does not repeat a denied permission request until the device is detached and reattached', 0, () => {
      const policy: UsbArcDevicePolicy = new UsbArcDevicePolicy();
      const device: UsbDeviceInfo = fixtureDevice('1-2');
      expect(policy.updateAttachment([device]).has(device.id)).assertTrue();
      expect(policy.shouldRequestPermission(device.id, true, false)).assertTrue();
      // A denied system request leaves the device unauthorized and the same attachment tracked.
      expect(policy.shouldRequestPermission(device.id, true, false)).assertFalse();
      policy.updateAttachment([]);
      expect(policy.updateAttachment([device]).has(device.id)).assertTrue();
      expect(policy.shouldRequestPermission(device.id, true, false)).assertTrue();
    });

    it('retries once after an explicit auto-permission re-enable but not on ordinary refresh', 0, () => {
      const policy: UsbArcDevicePolicy = new UsbArcDevicePolicy();
      const device: UsbDeviceInfo = fixtureDevice('1-2');
      policy.updateAttachment([device]);
      expect(policy.shouldRequestPermission(device.id, true, false)).assertTrue();
      // Refreshes during the same attachment do not repeatedly raise system prompts.
      expect(policy.shouldRequestPermission(device.id, true, false)).assertFalse();
      // Re-enabling the setting is an explicit user action, so it may retry once.
      policy.resetPermissionAttempt(device.id);
      expect(policy.shouldRequestPermission(device.id, true, false)).assertTrue();
      expect(policy.shouldRequestPermission(device.id, true, false)).assertFalse();
      // A detach/reattach remains a fresh attachment and permits one new request.
      policy.updateAttachment([]);
      policy.updateAttachment([device]);
      expect(policy.shouldRequestPermission(device.id, true, false)).assertTrue();
      expect(policy.shouldRequestPermission(device.id, true, false)).assertFalse();
    });

    it('matches all devices or only VID/PID/serial rules according to scope', 0, () => {
      const policy: UsbArcDevicePolicy = new UsbArcDevicePolicy();
      const device: UsbDeviceInfo = fixtureDevice('1-2');
      const settings: UsbArcPreferencesData = preferences();
      expect(policy.matchesAutoShare(settings, device)).assertTrue();
      settings.autoShareScope = 'rules';
      settings.rules.push({
        id: 'vid-pid', vendorIdHex: '1234', productIdHex: 'abcd', serialNumber: ''
      });
      expect(policy.matchesAutoShare(settings, device)).assertTrue();
      device.serialNumber = '';
      settings.rules[0].serialNumber = 'SERIAL-1';
      expect(policy.matchesAutoShare(settings, device)).assertFalse();
      device.serialNumber = 'SERIAL-1';
      expect(policy.matchesAutoShare(settings, device)).assertTrue();
      device.vendorId = 0x1235;
      expect(policy.matchesAutoShare(settings, device)).assertFalse();
    });

    it('keeps manual sharing independent from automatic sharing rules', 0, () => {
      const policy: UsbArcDevicePolicy = new UsbArcDevicePolicy();
      const device: UsbDeviceInfo = fixtureDevice('1-2');
      const settings: UsbArcPreferencesData = preferences();
      settings.autoShareScope = 'rules';
      expect(policy.matchesAutoShare(settings, device)).assertFalse();
      expect(policy.canManuallyShare(device)).assertTrue();
      device.authorized = false;
      expect(policy.canManuallyShare(device)).assertFalse();
    });
  });
}
