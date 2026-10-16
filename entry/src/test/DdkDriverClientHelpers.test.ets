import { describe, it, expect } from '@ohos/hypium';
import {
  getDdkTransferExpectation,
  isValidDdkTransferResult,
  mapDdkUsbErrno,
  normalizeDdkTimeout,
  validateDdkTransferRequest
} from '../main/ets/services/DdkDriverClient';
import {
  DdkDriverWireReply,
  normalizeNativeDdkReply,
  parseDdkDriverWireRequest
} from '../main/ets/services/DdkDriverRpcContract';
import {
  activeConfigurationFirst,
  findDdkEndpoint,
  makeDdkUsbIpBusId,
  parseDdkConfigurationDescriptor,
  selectUniqueDdkMatch
} from '../main/ets/usb/UsbDdkBackend';
import { DdkConfigurationDescriptor, DdkDeviceDescriptor, DdkSystemDeviceInfo } from '../main/ets/services/DdkDriverClient';

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
  });
}
