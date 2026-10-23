import { describe, it, expect } from '@ohos/hypium';
import { UsbArcPreferences, UsbArcPreferencesData } from '../main/ets/services/UsbArcPreferences';
import { describeUsbManagerClaimFailure } from '../main/ets/usb/UsbManagerClaimFailure';

interface PersistedBackendPreferenceInput {
  backendMode: 'usbDdk' | 'usbManager';
  forceClaim: boolean;
}

export default function UsbManagerClaimFailureTest() {
  describe('UsbManagerClaimFailureTest', () => {
    it('explains only a non-forced storage interface SDK -1 failure as a possible local mount', 0, () => {
      const storageMessage: string = describeUsbManagerClaimFailure(0, -1, 8, false);
      expect(storageMessage.includes('存储接口 0')).assertTrue();
      expect(storageMessage.includes('USB SDK -1：驱动异常')).assertTrue();
      expect(storageMessage.includes('可能仍被本机挂载')).assertTrue();
      expect(storageMessage.includes('请先安全弹出卷后重试')).assertTrue();
      expect(storageMessage.includes('在设置中手动开启')).assertTrue();
      expect(storageMessage.includes('自动')).assertFalse();
    });

    it('keeps the original SDK classification for non-storage, permission, and forced failures', 0, () => {
      expect(describeUsbManagerClaimFailure(2, -1, 2, false))
        .assertEqual('USB interface 2 claim failed (USB SDK code -1)');
      expect(describeUsbManagerClaimFailure(0, 88080488, 8, false))
        .assertEqual('USB interface 0 claim failed (USB SDK code 88080488)');
      expect(describeUsbManagerClaimFailure(0, -1, 8, true))
        .assertEqual('USB interface 0 claim failed (USB SDK code -1)');
    });

    it('normalizes a persisted force-claim value off for the DDK backend only', 0, () => {
      const oldDdkPreferences: PersistedBackendPreferenceInput = {
        backendMode: 'usbDdk',
        forceClaim: true
      };
      const normalizedDdk: UsbArcPreferencesData = UsbArcPreferences.normalize(oldDdkPreferences as Object);
      expect(normalizedDdk.backendMode).assertEqual('usbDdk');
      expect(normalizedDdk.forceClaim).assertFalse();

      const managerPreferences: PersistedBackendPreferenceInput = {
        backendMode: 'usbManager',
        forceClaim: true
      };
      expect(UsbArcPreferences.normalize(managerPreferences as Object).forceClaim).assertTrue();
    });
  });
}
