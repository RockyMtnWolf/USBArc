import { describe, it, expect } from '@ohos/hypium';
import {
  UsbNegotiatedSpeedDeviceIdentity,
  sameUsbSpeedDeviceIdentity,
  selectUniqueUsbSpeedDeviceIndex
} from '../main/ets/services/UsbNegotiatedSpeed';
import { UsbPhysicalAddress } from '../main/ets/usb/UsbDeviceMetadata';

function device(
  vendorId: number, productId: number, busNum: number, devAddress: number, name: string
): UsbNegotiatedSpeedDeviceIdentity {
  return { vendorId, productId, busNum, devAddress, name };
}

export default function UsbNegotiatedSpeedTest() {
  describe('UsbNegotiatedSpeed', () => {
    it('selects the sole exact VID PID match', 0, () => {
      const devices: Array<UsbNegotiatedSpeedDeviceIdentity> = [
        device(0x1a86, 0x7523, 2, 4, 'usb-2-4'),
        device(0x10c4, 0xea60, 2, 5, 'usb-2-5')
      ];
      expect(selectUniqueUsbSpeedDeviceIndex(devices, 0x1a86, 0x7523)).assertEqual(0);
      expect(selectUniqueUsbSpeedDeviceIndex(devices, 0x1a86, 0xffff)).assertEqual(-1);
    });

    it('rejects duplicate VID PID devices as ambiguous', 0, () => {
      const devices: Array<UsbNegotiatedSpeedDeviceIdentity> = [
        device(0x1a86, 0x7523, 2, 4, 'usb-2-4'),
        device(0x1a86, 0x7523, 3, 1, 'usb-3-1')
      ];
      const secondDeviceAddress: UsbPhysicalAddress = { busNum: 3, devAddress: 1 };
      const missingDeviceAddress: UsbPhysicalAddress = { busNum: 4, devAddress: 1 };
      expect(selectUniqueUsbSpeedDeviceIndex(devices, 0x1a86, 0x7523)).assertEqual(-1);
      expect(selectUniqueUsbSpeedDeviceIndex(devices, 0x1a86, 0x7523, secondDeviceAddress)).assertEqual(1);
      expect(selectUniqueUsbSpeedDeviceIndex(devices, 0x1a86, 0x7523, missingDeviceAddress)).assertEqual(-1);
    });

    it('requires the physical manager identity to stay stable', 0, () => {
      const original: UsbNegotiatedSpeedDeviceIdentity = device(0x1a86, 0x7523, 2, 4, 'usb-2-4');
      expect(sameUsbSpeedDeviceIdentity(original, device(0x1a86, 0x7523, 2, 4, 'usb-2-4'))).assertTrue();
      expect(sameUsbSpeedDeviceIdentity(original, device(0x1a86, 0x7523, 2, 5, 'usb-2-5'))).assertFalse();
      expect(sameUsbSpeedDeviceIdentity(original, device(0x1a86, 0x7523, 2, 4, 'replacement'))).assertFalse();
      expect(sameUsbSpeedDeviceIdentity(original, device(0x1a86, 0xffff, 2, 4, 'usb-2-4'))).assertFalse();
    });
  });
}
