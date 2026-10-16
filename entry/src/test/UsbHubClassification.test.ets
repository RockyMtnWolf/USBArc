import { describe, it, expect } from '@ohos/hypium';
import {
  isProvableUsbHub,
  shouldHideDdkHubRow,
  UsbHubDeviceDescriptor,
  UsbHubInterfaceDescriptor
} from '../main/ets/usb/UsbHubClassification';

function fixture(
  clazz: number, interfaceClasses: Array<number>, vendorId: number = 0x2109, productId: number = 0x0817
): UsbHubDeviceDescriptor {
  return {
    vendorId,
    productId,
    clazz,
    configs: interfaceClasses.length === 0 ? [] : [{
      interfaces: interfaceClasses.map((item: number): UsbHubInterfaceDescriptor => ({ clazz: item }))
    }]
  };
}

export default function UsbHubClassificationTest() {
  describe('UsbHubClassification', () => {
    it('recognizes a device-level hub class', 0, () => {
      expect(isProvableUsbHub(fixture(0x09, []))).assertTrue();
    });

    it('recognizes class zero only when all interfaces are hubs', 0, () => {
      expect(isProvableUsbHub(fixture(0, [0x09]))).assertTrue();
      expect(isProvableUsbHub(fixture(0, [0x09, 0x09]))).assertTrue();
      expect(isProvableUsbHub(fixture(0, [0x09, 0x08]))).assertFalse();
      expect(isProvableUsbHub(fixture(0, []))).assertFalse();
      expect(isProvableUsbHub(fixture(0x08, [0x09]))).assertFalse();
    });

    it('hides a DDK row only when every matching manager row proves hub class', 0, () => {
      const hub: UsbHubDeviceDescriptor = fixture(0x09, []);
      const nonHub: UsbHubDeviceDescriptor = fixture(0x08, [], 0x2109, 0x0817);
      expect(shouldHideDdkHubRow(0x2109, 0x0817, [hub])).assertTrue();
      expect(shouldHideDdkHubRow(0x2109, 0x0817, [hub, fixture(0x09, [])])).assertTrue();
      expect(shouldHideDdkHubRow(0x2109, 0x0817, [hub, nonHub])).assertFalse();
      expect(shouldHideDdkHubRow(0x2109, 0x0817, [])).assertFalse();
      expect(shouldHideDdkHubRow(0x1234, 0x5678, [hub])).assertFalse();
    });
  });
}
