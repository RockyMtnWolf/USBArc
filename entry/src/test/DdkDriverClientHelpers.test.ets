import { describe, it, expect } from '@ohos/hypium';
import {
  classifyDdkDriverHealth,
  formatDdkPlatformErrorMessage,
  getDdkTransferExpectation,
  isValidDdkTransferResult,
  mapDdkUsbErrno,
  normalizeDdkTimeout,
  validateDdkTransferRequest
} from '../main/ets/services/DdkDriverClient';
import {
  cleanupDdkAshmem,
  MAX_DDK_SHARED_TRANSFER_BYTES,
  DdkDriverWireReply,
  normalizeNativeDdkReply,
  parseDdkDriverWireRequest,
  validateDdkSharedTransfer,
  validateDdkSharedTransferResult
} from '../main/ets/services/DdkDriverRpcContract';
import {
  activeConfigurationFirst,
  decodeDdkUsbString,
  ddkDisplayName,
  findDdkEndpoint,
  makeDdkUsbIpBusId,
  parseDdkConfigurationDescriptor,
  selectUniqueDdkMatch
} from '../main/ets/usb/UsbDdkBackend';
import { mapUsbManagerClaimError } from '../main/ets/usb/UsbManagerBackend';
import { DdkConfigurationDescriptor, DdkDeviceDescriptor, DdkSystemDeviceInfo } from '../main/ets/services/DdkDriverClient';
import { makeDdkProbeDeviceId } from '../main/ets/services/DdkReadOnlyProbe';

function configFixture(): DdkConfigurationDescriptor {
  return {
    configurationValue: 1,
    attributes: 0x80,
    maxPower: 50,
    interfaceCount: 1,
    bytes: [
      9, 2, 25, 0, 1, 1, 0, 0x80, 50,
      9, 4, 2, 0, 1, 0xff, 0, 0, 0,
      7, 5, 0x81, 2, 64, 0, 1
    ]
  };
}

function descriptor(id: string, vendorId: number, productId: number): DdkDeviceDescriptor {
  return {
    id,
    bytes: [],
    vendorId,
    productId,
    deviceClass: 0,
    deviceSubClass: 0,
    deviceProtocol: 0,
    bcdUsb: 0x0200,
    bcdDevice: 0x0100,
    maxPacketSize0: 64,
    configurationCount: 1
  };
}

export default function DdkDriverClientHelpersTest() {
  describe('DdkDriverClientHelpersTest', () => {
    it('constructs exact uint64 DDK IDs from safe USBManager bus and address values', 0, () => {
      expect(makeDdkProbeDeviceId(1, 6)).assertEqual('4294967302');
      expect(makeDdkProbeDeviceId(0x1fffff, 127)).assertEqual('9007194959773823');
      expect(makeDdkProbeDeviceId(0x200000, 1)).assertEqual(undefined);
      expect(makeDdkProbeDeviceId(1.5, 1)).assertEqual(undefined);
      expect(makeDdkProbeDeviceId(1, 128)).assertEqual(undefined);
    });

    it('decodes real UTF16 USB product strings and refuses malformed descriptors', 0, () => {
      expect(decodeDdkUsbString([8, 3, 67, 0, 72, 0, 52, 0])).assertEqual('CH4');
      expect(decodeDdkUsbString([4, 3, 0x2d, 0x4e])).assertEqual('中');
      expect(decodeDdkUsbString([8, 3, 67, 0])).assertEqual('');
      expect(decodeDdkUsbString([3, 3, 67])).assertEqual('');
      expect(decodeDdkUsbString([4, 2, 67, 0])).assertEqual('');
      expect(decodeDdkUsbString([4, 3, 256, 0])).assertEqual('');
    });

    it('uses actual product strings before descriptions and never treats hardware paths as names', 0, () => {
      const hardwarePath: string = 'USB&BUS_02&DEV_02&PID_7523&VID_1A86&CLASS_00';
      expect(ddkDisplayName('USB2.0-Serial', hardwarePath, 0x1a86, 0x7523)).assertEqual('USB2.0-Serial');
      expect(ddkDisplayName('', hardwarePath, 0x1a86, 0x7523)).assertEqual('USB 1A86:7523');
      expect(ddkDisplayName('', 'USB Hub', 0x1234, 0x0001)).assertEqual('USB Hub');
      expect(ddkDisplayName('', '', 0x1234, 0x0001)).assertEqual('USB 1234:0001');
    });

    it('requires explicit resource-release confirmation before classifying a stopped extension as clean', 0, () => {
      expect(classifyDdkDriverHealth(0, true, false)).assertEqual('healthy');
      expect(classifyDdkDriverHealth(27400002, false, true)).assertEqual('released');
      expect(classifyDdkDriverHealth(27400002, false, false)).assertEqual('unavailable');
      expect(classifyDdkDriverHealth(-5, undefined, undefined)).assertEqual('unavailable');
    });

    it('normalizes an opaque DDK ID as a stable logical USB/IP bus ID', 0, () => {
      expect(makeDdkUsbIpBusId('184467')).assertEqual('ddk-184467');
    });

    it('parses device configuration, interface, and endpoint descriptor bytes', 0, () => {
      const parsed = parseDdkConfigurationDescriptor(configFixture(), 0);
      expect(parsed.id).assertEqual(1);
      expect(parsed.interfaces.length).assertEqual(1);
      expect(parsed.interfaces[0].id).assertEqual(2);
      expect(parsed.interfaces[0].endpoints[0].address).assertEqual(0x81);
      expect(parsed.interfaces[0].endpoints[0].maxPacketSize).assertEqual(64);
    });

    it('places the actual GET_CONFIGURATION value first without assuming descriptor order', 0, () => {
      const first = parseDdkConfigurationDescriptor(configFixture(), 0);
      const secondFixture = configFixture();
      secondFixture.configurationValue = 7;
      secondFixture.bytes[5] = 7;
      const second = parseDdkConfigurationDescriptor(secondFixture, 1);
      const ordered = activeConfigurationFirst([first, second], 7);
      expect(ordered[0].id).assertEqual(7);
      expect(ordered[0].index).assertEqual(1);
    });

    it('maps endpoint number and direction to distinct IN and OUT USB addresses', 0, () => {
      const configuration = parseDdkConfigurationDescriptor({
        configurationValue: 1,
        attributes: 0x80,
        maxPower: 50,
        interfaceCount: 1,
        bytes: [
          9, 2, 32, 0, 1, 1, 0, 0x80, 50,
          9, 4, 2, 0, 2, 0xff, 0, 0, 0,
          7, 5, 1, 2, 64, 0, 1,
          7, 5, 0x81, 2, 64, 0, 1
        ]
      }, 0);
      const alternates: Map<number, number> = new Map<number, number>();
      alternates.set(2, 0);
      expect(findDdkEndpoint([configuration], 1, alternates, 1, 0)?.address).assertEqual(1);
      expect(findDdkEndpoint([configuration], 1, alternates, 1, 1)?.address).assertEqual(0x81);
    });

    it('matches only a unique VID/PID DDK candidate', 0, () => {
      const system: DdkSystemDeviceInfo = { deviceId: 4, vendorId: 0x1a86, productId: 0x55d3, description: 'serial' };
      const match: DdkDeviceDescriptor = descriptor('7', 0x1a86, 0x55d3);
      const other: DdkDeviceDescriptor = descriptor('8', 0x1234, 0xabcd);
      expect(selectUniqueDdkMatch(system, [other, match]).id).assertEqual('7');
      let ambiguous: boolean = false;
      try {
        selectUniqueDdkMatch(system, [match, descriptor('9', 0x1a86, 0x55d3)]);
      } catch (_error) {
        ambiguous = true;
      }
      expect(ambiguous).assertTrue();
    });

    it('requires DDK RPC byte arrays to be valid instead of silently dropping bytes', 0, () => {
      const request = parseDdkDriverWireRequest('{"operation":"pipeTransfer","data":[1,255]}');
      expect(request.data.length).assertEqual(2);
      let invalidRejected: boolean = false;
      try {
        parseDdkDriverWireRequest('{"operation":"pipeTransfer","data":[256]}');
      } catch (_error) {
        invalidRejected = true;
      }
      expect(invalidRejected).assertTrue();
    });

    it('keeps a 64 KiB IN/OUT URB atomic in shared memory and accepts exact short IN packets', 0, () => {
      const transferLength: number = 65536;
      validateDdkSharedTransfer('pipeTransfer', true, transferLength, transferLength, 0);
      const outValid: boolean = validateDdkSharedTransferResult(false, transferLength, transferLength, []);
      const shortInput: Array<number> = new Array<number>(32768).fill(0x5a);
      const shortInputValid: boolean = validateDdkSharedTransferResult(true, transferLength,
        shortInput.length, shortInput);
      expect(outValid).assertTrue();
      expect(shortInputValid).assertTrue();
      expect(validateDdkSharedTransferResult(true, transferLength, shortInput.length, new Array<number>(transferLength).fill(0))).assertFalse();
      expect(validateDdkSharedTransferResult(false, transferLength, transferLength, [1])).assertFalse();
      expect(MAX_DDK_SHARED_TRANSFER_BYTES).assertEqual(1048576);
    });

    it('rejects missing shared-memory payloads and guarantees unmap/close cleanup on errors', 0, () => {
      let malformedRejected: boolean = false;
      try {
        validateDdkSharedTransfer('pipeTransfer', true, 65536, 65536, 1);
      } catch (_error) {
        malformedRejected = true;
      }
      expect(malformedRejected).assertTrue();
      let oversizedRejected: boolean = false;
      try {
        validateDdkSharedTransfer('pipeTransfer', true, MAX_DDK_SHARED_TRANSFER_BYTES + 1,
          MAX_DDK_SHARED_TRANSFER_BYTES + 1, 0);
      } catch (_error) {
        oversizedRejected = true;
      }
      expect(oversizedRejected).assertTrue();

      const cleanupOrder: Array<string> = [];
      let cleanupFailed: boolean = false;
      try {
        cleanupDdkAshmem((): void => {
          cleanupOrder.push('unmap');
          throw new Error('injected unmap failure');
        }, (): void => { cleanupOrder.push('close'); }, true);
      } catch (_error) {
        cleanupFailed = true;
      }
      expect(cleanupFailed).assertTrue();
      expect(cleanupOrder.join(',')).assertEqual('unmap,close');
    });

    it('flattens native status-value responses and preserves transfer lengths', 0, () => {
      const transferReply: DdkDriverWireReply = { status: 0, actualLength: 2, data: [4, 5] };
      const valueReply: DdkDriverWireReply = { status: 0, value: ['33'] };
      const reply = normalizeNativeDdkReply(transferReply as Object);
      expect(reply.status).assertEqual(0);
      expect(reply.actualLength).assertEqual(2);
      expect(reply.data?.length).assertEqual(2);
      expect(normalizeNativeDdkReply(valueReply as Object).value !== undefined).assertTrue();
    });

    it('keeps transfer direction, payload, timeout, and errno validation explicit', 0, () => {
      const inExpectation = validateDdkTransferRequest('pipeTransfer', 0x81, [], [0, 0, 0]);
      expect(inExpectation.isInput).assertTrue();
      expect(isValidDdkTransferResult(inExpectation, 2, [1, 2])).assertTrue();
      const outExpectation = getDdkTransferExpectation('pipeTransfer', 0x02, [], [1, 2]);
      expect(outExpectation.isInput).assertFalse();
      expect(isValidDdkTransferResult(outExpectation, 2, [])).assertTrue();
      const controlOut = getDdkTransferExpectation('claimedControlTransfer', 0,
        [0x00, 9, 1, 0, 0, 0, 2, 0], [3, 4]);
      expect(controlOut.isInput).assertFalse();
      expect(isValidDdkTransferResult(controlOut, 2, [])).assertTrue();
      const controlIn = getDdkTransferExpectation('claimedControlTransfer', 0,
        [0x80, 6, 0, 1, 0, 0, 2, 0], [0, 0]);
      expect(controlIn.isInput).assertTrue();
      expect(isValidDdkTransferResult(controlIn, 2, [18, 1])).assertTrue();
      expect(normalizeDdkTimeout(0)).assertEqual(10000);
      expect(mapDdkUsbErrno(201)).assertEqual(-13);
      expect(mapDdkUsbErrno(-90)).assertEqual(-90);
    });

    it('maps documented manager claim failures without calling driver errors busy', 0, () => {
      expect(mapUsbManagerClaimError(88080389)).assertEqual(-19);
      expect(mapUsbManagerClaimError(88080486)).assertEqual(-11);
      expect(mapUsbManagerClaimError(88080488)).assertEqual(-13);
      expect(mapUsbManagerClaimError(-1)).assertEqual(-5);
      expect(mapUsbManagerClaimError(401)).assertEqual(-22);
      expect(mapUsbManagerClaimError(801)).assertEqual(-95);
      expect(mapUsbManagerClaimError(987654)).assertEqual(-5);
    });

    it('keeps ExternalDeviceManager platform codes visible in bind errors', 0, () => {
      expect(mapDdkUsbErrno(22900001)).assertEqual(-5);
      expect(mapDdkUsbErrno(26300001)).assertEqual(-5);
      expect(formatDdkPlatformErrorMessage('bind DDK driver', 22900001,
        'ExternalDeviceManager service exception')).assertEqual(
        'bind DDK driver failed (platform code 22900001): ExternalDeviceManager service exception');
    });

  });
}
