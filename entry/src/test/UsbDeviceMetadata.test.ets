import { describe, it, expect } from '@ohos/hypium';
import {
  mergeUsbDisplayMetadata,
  parseDdkUsbPhysicalAddress,
  selectUsbManagerMetadata,
  UsbManagerDeviceMetadata
} from '../main/ets/usb/UsbDeviceMetadata';

function metadata(busNum: number, devAddress: number, productName: string, serialNumber: string): UsbManagerDeviceMetadata {
  return {
    vendorId: 0x1a86,
    productId: 0x7523,
    busNum,
    devAddress,
    manufacturerName: 'QinHeng',
    productName,
    serialNumber
  };
}

export default function UsbDeviceMetadataTest() {
  describe('UsbDeviceMetadata', () => {
    it('parses verified bus and device numbers as hexadecimal', 0, () => {
      const address = parseDdkUsbPhysicalAddress(
        'USB&BUS_03&DEV_13&PID_7523&VID_1A86&CLASS_FF', 0x1a86, 0x7523);
      expect(address?.busNum).assertEqual(3);
      expect(address?.devAddress).assertEqual(19);
      expect(parseDdkUsbPhysicalAddress(
        'USB&BUS_03&DEV_13&PID_7524&VID_1A86&CLASS_FF', 0x1a86, 0x7523)).assertEqual(undefined);
    });

    it('matches the exact physical device when multiple devices share VID/PID', 0, () => {
      const first: UsbManagerDeviceMetadata = metadata(3, 18, 'Adapter A', 'A-1');
      const second: UsbManagerDeviceMetadata = metadata(3, 19, 'Adapter B', 'B-2');
      const selected: UsbManagerDeviceMetadata | undefined = selectUsbManagerMetadata(
        0x1a86, 0x7523, 'USB&BUS_03&DEV_13&PID_7523&VID_1A86&CLASS_FF', [first, second]);
      expect(selected?.productName).assertEqual('Adapter B');
      expect(selected?.serialNumber).assertEqual('B-2');
      const byAddress: UsbManagerDeviceMetadata | undefined = selectUsbManagerMetadata(
        0x1a86, 0x7523, 'USB2.0-Serial', [first, second], { busNum: 3, devAddress: 19 });
      expect(byAddress?.productName).assertEqual('Adapter B');
    });

    it('uses VID/PID only for a unique candidate and rejects ambiguous mappings', 0, () => {
      const first: UsbManagerDeviceMetadata = metadata(3, 18, 'Only device', 'S-1');
      const second: UsbManagerDeviceMetadata = metadata(3, 19, 'Other device', 'S-2');
      expect(selectUsbManagerMetadata(0x1a86, 0x7523, 'USB device', [first])?.productName)
        .assertEqual('Only device');
      expect(selectUsbManagerMetadata(0x1a86, 0x7523, 'USB device', [first, second])).assertEqual(undefined);
      expect(selectUsbManagerMetadata(0x1a86, 0x7523,
        'USB&BUS_03&DEV_14&PID_7523&VID_1A86&CLASS_FF', [first])).assertEqual(undefined);
    });

    it('prefers nonempty manager metadata and falls back field by field to DDK strings', 0, () => {
      const manager: UsbManagerDeviceMetadata = metadata(3, 19, '  ', ' S-2 ');
      manager.manufacturerName = ' ';
      const merged = mergeUsbDisplayMetadata(manager, {
        manufacturer: ' DDK manufacturer ',
        product: ' DDK product ',
        serialNumber: ' DDK serial '
      });
      expect(merged.manufacturer).assertEqual('DDK manufacturer');
      expect(merged.product).assertEqual('DDK product');
      expect(merged.serialNumber).assertEqual('S-2');
    });
  });
}
