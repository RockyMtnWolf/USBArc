import { describe, it, expect } from '@ohos/hypium';
import {
  MAX_TRANSFER_BYTES,
  OP_REP_DEVLIST,
  USBIP_DIR_IN,
  USBIP_NON_ISO_PACKETS,
  USBIP_RET_SUBMIT,
  USBIP_RET_UNLINK,
  UsbIpSubmitRequest,
  concatBytes,
  nextFrameLength,
  parseSetupPacket,
  parseSubmit,
  parseUnlink,
  readU16,
  readU32,
  writeU16,
  writeU32
} from '../main/ets/protocol/UsbIpWire';
import {
  beginUnlink,
  cancelAndClearPendingTransfers,
  classifyUsbHandleCloseDisposition,
  classifyUnlinkTarget,
  completePendingTransfer,
  finishActiveUnlink,
  isUsbDeviceExportable,
  mergeUsbHandleRetention,
  PendingTransfer,
  shouldRetainSharedUsbHandle,
  UsbIpServerService,
  usbIpSubmitDirection
} from '../main/ets/services/UsbIpServer';
import { UsbDeviceInfo } from '../main/ets/usb/UsbModels';

function makeSubmitHeader(direction: number, endpoint: number, transferLength: number, packetCount: number): Uint8Array {
  const frame: Uint8Array = new Uint8Array(48);
  frame.set([
    0x00, 0x00, 0x00, 0x01, // USBIP_CMD_SUBMIT
    0x01, 0x02, 0x03, 0x04, // seqnum
    0x00, 0x00, 0x00, 0x07, // devid
    (direction >>> 24) & 0xff, (direction >>> 16) & 0xff, (direction >>> 8) & 0xff, direction & 0xff,
    0x00, 0x00, 0x00, endpoint,
    0x00, 0x00, 0x00, 0x00, // transfer_flags
    (transferLength >>> 24) & 0xff, (transferLength >>> 16) & 0xff, (transferLength >>> 8) & 0xff, transferLength & 0xff,
    0x00, 0x00, 0x00, 0x00, // start_frame
    (packetCount >>> 24) & 0xff, (packetCount >>> 16) & 0xff, (packetCount >>> 8) & 0xff, packetCount & 0xff,
    0x00, 0x00, 0x00, 0x00, // interval
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 // setup
  ]);
  return frame;
}

function testDevice(shared: boolean, occupied: boolean = true, closing: boolean = false): UsbDeviceInfo {
  return {
    id: 'test-device', name: 'Protocol fixture', path: '/usb/test/1', busId: '7-1',
    busNum: 7, devAddress: 1, vendorId: 0x1234, productId: 0xabcd, speed: 0,
    manufacturer: 'Fixture', product: 'Protocol fixture', serialNumber: '', version: '1.2',
    deviceClass: 0, deviceSubClass: 0, deviceProtocol: 0, configurations: [],
    authorized: true, occupied, shared, imported: false, closing, available: true
  };
}

function testRequest(seqnum: number, direction: number, endpoint: number): UsbIpSubmitRequest {
  return {
    seqnum, devid: 1, direction, endpoint, transferFlags: 0, transferLength: 0,
    startFrame: 0, numberOfPackets: 0, interval: 0,
    setup: new Uint8Array(8), payload: new Uint8Array(0)
  };
}

export default function UsbIpProtocolTest() {
  describe('UsbIpProtocolTest', () => {
    it('reads and writes USB/IP multibyte fields in network byte order', 0, () => {
      const known: Uint8Array = new Uint8Array([0x12, 0x34, 0x56, 0x78]);
      expect(readU16(known, 0)).assertEqual(0x1234);
      expect(readU32(known, 0)).assertEqual(0x12345678);
      const actual: Uint8Array = new Uint8Array(6);
      writeU16(actual, 0, 0x1234);
      writeU32(actual, 2, 0x5678);
      expect(actual[0]).assertEqual(0x12);
      expect(actual[1]).assertEqual(0x34);
      expect(actual[2]).assertEqual(0x00);
      expect(actual[3]).assertEqual(0x00);
      expect(actual[4]).assertEqual(0x56);
      expect(actual[5]).assertEqual(0x78);
    });

    it('waits for a complete operation header and consumes the exact DEVLIST frame', 0, () => {
      const request: Uint8Array = new Uint8Array([0x01, 0x11, 0x80, 0x05, 0x00, 0x00, 0x00, 0x00]);
      expect(nextFrameLength(request.slice(0, 3))).assertEqual(0);
      expect(nextFrameLength(request.slice(0, 7))).assertEqual(0);
      expect(nextFrameLength(request)).assertEqual(8);
      const next: Uint8Array = new Uint8Array([0x01, 0x11, 0x80, 0x05, 0, 0, 0, 0]);
      const coalesced: Uint8Array = concatBytes(request, next);
      expect(nextFrameLength(coalesced)).assertEqual(8);
      expect(nextFrameLength(coalesced.slice(8))).assertEqual(8);
    });

    it('waits for all OUT payload bytes and preserves the next coalesced frame', 0, () => {
      const header: Uint8Array = makeSubmitHeader(0, 1, 3, 0);
      const payload: Uint8Array = new Uint8Array([0xde, 0xad, 0xbe]);
      const submit: Uint8Array = concatBytes(header, payload);
      const unlink: Uint8Array = new Uint8Array([
        0, 0, 0, 2, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
      ]);
      expect(nextFrameLength(submit.slice(0, 48))).assertEqual(0);
      expect(nextFrameLength(submit)).assertEqual(51);
      const stream: Uint8Array = concatBytes(submit, unlink);
      expect(nextFrameLength(stream)).assertEqual(51);
      expect(nextFrameLength(stream.slice(51))).assertEqual(48);
      const parsed = parseSubmit(stream.slice(0, 51));
      expect(parsed.seqnum).assertEqual(0x01020304);
      expect(parsed.direction).assertEqual(0);
      expect(parsed.endpoint).assertEqual(1);
      expect(parsed.transferLength).assertEqual(3);
      expect(parsed.payload[0]).assertEqual(0xde);
      expect(parsed.payload[2]).assertEqual(0xbe);
      const parsedUnlink = parseUnlink(stream.slice(51));
      expect(parsedUnlink.seqnum).assertEqual(5);
      expect(parsedUnlink.targetSeqnum).assertEqual(4);
    });

    it('accepts both observed non-ISO packet markers and enforces transfer bounds', 0, () => {
      const zeroPacketMarker: Uint8Array = makeSubmitHeader(USBIP_DIR_IN, 0, MAX_TRANSFER_BYTES, 0);
      const sentinelMarker: Uint8Array = makeSubmitHeader(USBIP_DIR_IN, 0, 0, USBIP_NON_ISO_PACKETS);
      expect(nextFrameLength(zeroPacketMarker)).assertEqual(48);
      expect(nextFrameLength(sentinelMarker)).assertEqual(48);
      const oversized: Uint8Array = makeSubmitHeader(USBIP_DIR_IN, 0, MAX_TRANSFER_BYTES + 1, 0);
      let rejected: boolean = false;
      try {
        nextFrameLength(oversized);
      } catch (_error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('rejects invalid direction, endpoint, and isochronous packet counts', 0, () => {
      const invalidDirection: Uint8Array = makeSubmitHeader(2, 1, 0, 0);
      const invalidEndpoint: Uint8Array = makeSubmitHeader(0, 16, 0, 0);
      const isochronous: Uint8Array = makeSubmitHeader(USBIP_DIR_IN, 1, 0, 1);
      const assertRejected = (frame: Uint8Array): void => {
        let rejected: boolean = false;
        try { nextFrameLength(frame); } catch (_error) { rejected = true; }
        expect(rejected).assertTrue();
      };
      assertRejected(invalidDirection);
      assertRejected(invalidEndpoint);
      assertRejected(isochronous);
    });

    it('parses the USB GET_DESCRIPTOR setup packet as little-endian fields', 0, () => {
      const setup: Uint8Array = new Uint8Array([0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00]);
      const parsed = parseSetupPacket(setup);
      expect(parsed.requestType).assertEqual(0x80);
      expect(parsed.request).assertEqual(0x06);
      expect(parsed.value).assertEqual(0x0100);
      expect(parsed.index).assertEqual(0);
      expect(parsed.length).assertEqual(18);
    });

    it('builds descriptor records with protocol byte offsets and network order', 0, () => {
      const service: UsbIpServerService = new UsbIpServerService();
      const shared: UsbDeviceInfo = testDevice(true);
      const unshared: UsbDeviceInfo = testDevice(false);
      const reply: Uint8Array = service.buildDeviceListReplyFor([shared, unshared]);
      expect(reply.length).assertEqual(324);
      expect(reply[0]).assertEqual(0x01);
      expect(reply[1]).assertEqual(0x11);
      expect(reply[2]).assertEqual((OP_REP_DEVLIST >>> 8) & 0xff);
      expect(reply[3]).assertEqual(OP_REP_DEVLIST & 0xff);
      expect(readU32(reply, 8)).assertEqual(1);
      expect(readU32(reply, 300)).assertEqual(7);
      expect(readU32(reply, 304)).assertEqual(1);
      expect(reply[312]).assertEqual(0x12);
      expect(reply[313]).assertEqual(0x34);
      expect(reply[314]).assertEqual(0xab);
      expect(reply[315]).assertEqual(0xcd);
      expect(reply[316]).assertEqual(0x01);
      expect(reply[317]).assertEqual(0x02);
    });

    it('exports a device only when shared, occupied, and not closing', 0, () => {
      const service: UsbIpServerService = new UsbIpServerService();
      const sharedAndClaimed: UsbDeviceInfo = testDevice(true, true, false);
      const unshared: UsbDeviceInfo = testDevice(false, true, false);
      const notClaimed: UsbDeviceInfo = testDevice(true, false, false);
      const closing: UsbDeviceInfo = testDevice(true, true, true);
      expect(isUsbDeviceExportable(sharedAndClaimed)).assertTrue();
      expect(isUsbDeviceExportable(unshared)).assertFalse();
      expect(isUsbDeviceExportable(notClaimed)).assertFalse();
      expect(isUsbDeviceExportable(closing)).assertFalse();

      const reply: Uint8Array = service.buildDeviceListReplyFor([unshared, notClaimed, closing, sharedAndClaimed]);
      expect(readU32(reply, 8)).assertEqual(1);
      expect(reply.length).assertEqual(324);
    });

    it('retains a selected claim after client disconnect only while the server runs', 0, () => {
      expect(shouldRetainSharedUsbHandle(true, true, undefined)).assertTrue();
      expect(shouldRetainSharedUsbHandle(false, true, undefined)).assertFalse();
      expect(shouldRetainSharedUsbHandle(true, false, undefined)).assertFalse();
      expect(shouldRetainSharedUsbHandle(true, true, false)).assertFalse();
      expect(shouldRetainSharedUsbHandle(false, false, true)).assertFalse();
      expect(mergeUsbHandleRetention(true, undefined)).assertTrue();
      expect(mergeUsbHandleRetention(true, false)).assertFalse();
      expect(mergeUsbHandleRetention(false, true)).assertFalse();
    });

    it('builds the IMPORT descriptor record at the protocol-defined offsets', 0, () => {
      const service: UsbIpServerService = new UsbIpServerService();
      const reply: Uint8Array = service.buildImportReply(testDevice(true));
      expect(reply.length).assertEqual(320);
      expect(reply[0]).assertEqual(0x01);
      expect(reply[1]).assertEqual(0x11);
      expect(reply[2]).assertEqual(0x00);
      expect(reply[3]).assertEqual(0x03);
      expect(reply[8]).assertEqual(0x2f);
      expect(reply[9]).assertEqual(0x75);
      expect(reply[10]).assertEqual(0x73);
      expect(reply[11]).assertEqual(0x62);
      expect(reply[264]).assertEqual(0x37);
      expect(reply[265]).assertEqual(0x2d);
      expect(readU32(reply, 296)).assertEqual(7);
      expect(readU32(reply, 300)).assertEqual(1);
      expect(reply[308]).assertEqual(0x12);
      expect(reply[309]).assertEqual(0x34);
      expect(reply[310]).assertEqual(0xab);
      expect(reply[311]).assertEqual(0xcd);
      expect(reply[312]).assertEqual(0x01);
      expect(reply[313]).assertEqual(0x02);
    });

    it('uses the USB/IP header direction when URB_DIR_IN is absent from flags', 0, () => {
      const request: UsbIpSubmitRequest = testRequest(8, USBIP_DIR_IN, 1);
      request.transferFlags = 0;
      expect(usbIpSubmitDirection(request)).assertEqual(USBIP_DIR_IN);
    });

    it('builds successful cancellation and submit reply headers with zero server basic fields', 0, () => {
      const service: UsbIpServerService = new UsbIpServerService();
      const request: UsbIpSubmitRequest = {
        seqnum: 0x01020304, devid: 0x00070001, direction: 1, endpoint: 2,
        transferFlags: 0, transferLength: 2, startFrame: 0, numberOfPackets: 0,
        interval: 1, setup: new Uint8Array(8), payload: new Uint8Array(0)
      };
      const submit: Uint8Array = service.buildSubmitReply(request, 0, 2, new Uint8Array([0x56, 0x78]));
      expect(submit.length).assertEqual(50);
      expect(submit[0]).assertEqual(0);
      expect(submit[1]).assertEqual(0);
      expect(submit[2]).assertEqual(0);
      expect(submit[3]).assertEqual(USBIP_RET_SUBMIT);
      expect(readU32(submit, 4)).assertEqual(0x01020304);
      expect(readU32(submit, 8)).assertEqual(0);
      expect(readU32(submit, 12)).assertEqual(0);
      expect(readU32(submit, 16)).assertEqual(0);
      expect(submit[48]).assertEqual(0x56);
      expect(submit[49]).assertEqual(0x78);
      const cancelled: Uint8Array = service.buildUnlinkReply(9, -104);
      expect(cancelled[3]).assertEqual(USBIP_RET_UNLINK);
      expect(readU32(cancelled, 4)).assertEqual(9);
      expect(readU32(cancelled, 20)).assertEqual(0xffffff98);
      expect(readU32(service.buildUnlinkReply(10, 0), 20)).assertEqual(0);
    });

    it('suppresses RET_SUBMIT after successful queued or active cancellation', 0, () => {
      const request: UsbIpSubmitRequest = testRequest(1, 0, 1);
      const queued: PendingTransfer = {
        request, endpointKey: '0:1', state: 'queued', cancelled: false, control: false, cancel: undefined
      };
      const queuedMap: Map<number, PendingTransfer> = new Map<number, PendingTransfer>();
      queuedMap.set(1, queued);
      const queuedResult = beginUnlink(queuedMap, 1);
      expect(queuedResult.status).assertEqual(-104);
      expect(queuedResult.suppressSubmit).assertTrue();
      expect(queuedMap.has(1)).assertFalse();
      expect(completePendingTransfer(queuedMap, 1, queued)).assertFalse();

      const active: PendingTransfer = {
        request, endpointKey: '0:1', state: 'running', cancelled: false, control: false, cancel: (): boolean => true
      };
      const activeMap: Map<number, PendingTransfer> = new Map<number, PendingTransfer>();
      activeMap.set(1, active);
      const activeResult = beginUnlink(activeMap, 1);
      expect(activeResult.disposition).assertEqual('cancel-active');
      expect(activeResult.status).assertEqual(0);
      const cancelled = finishActiveUnlink(activeMap, 1, active, active.cancel !== undefined && active.cancel());
      expect(cancelled.status).assertEqual(-104);
      expect(cancelled.suppressSubmit).assertTrue();
      expect(activeMap.has(1)).assertFalse();
      expect(completePendingTransfer(activeMap, 1, active)).assertFalse();
    });

    it('reports active cancellation failure without suppressing the original submit reply', 0, () => {
      const request: UsbIpSubmitRequest = testRequest(5, 0, 1);
      const active: PendingTransfer = {
        request, endpointKey: '0:1', state: 'running', cancelled: false, control: false, cancel: (): boolean => false
      };
      const pending: Map<number, PendingTransfer> = new Map<number, PendingTransfer>();
      pending.set(5, active);
      const transition = finishActiveUnlink(pending, 5, active, active.cancel !== undefined && active.cancel());
      expect(transition.status).assertEqual(0);
      expect(transition.suppressSubmit).assertFalse();
      expect(pending.has(5)).assertTrue();
      expect(completePendingTransfer(pending, 5, active)).assertTrue();
    });

    it('cancels a queued control transfer but leaves a running control transfer non-cancellable', 0, () => {
      const queued: PendingTransfer = {
        request: testRequest(6, 0, 0), endpointKey: 'control', state: 'queued', cancelled: false,
        control: true, cancel: undefined
      };
      const queuedMap: Map<number, PendingTransfer> = new Map<number, PendingTransfer>();
      queuedMap.set(6, queued);
      const queuedUnlink = beginUnlink(queuedMap, 6);
      expect(queuedUnlink.disposition).assertEqual('cancel-queued');
      expect(queuedUnlink.status).assertEqual(-104);
      expect(queuedUnlink.suppressSubmit).assertTrue();
      expect(queuedMap.has(6)).assertFalse();
      expect(completePendingTransfer(queuedMap, 6, queued)).assertFalse();

      const running: PendingTransfer = {
        request: testRequest(7, 0, 0), endpointKey: 'control', state: 'running', cancelled: false,
        control: true, cancel: undefined
      };
      const runningMap: Map<number, PendingTransfer> = new Map<number, PendingTransfer>();
      runningMap.set(7, running);
      const runningUnlink = beginUnlink(runningMap, 7);
      expect(runningUnlink.disposition).assertEqual('non-cancellable-control');
      expect(runningUnlink.status).assertEqual(-95);
      expect(runningUnlink.suppressSubmit).assertFalse();
      expect(runningMap.has(7)).assertTrue();
    });

    it('keeps the submit reply when completion wins the UNLINK race', 0, () => {
      const request: UsbIpSubmitRequest = testRequest(2, 1, 1);
      const completed: PendingTransfer = {
        request, endpointKey: '1:1', state: 'running', cancelled: false, control: false, cancel: undefined
      };
      const pending: Map<number, PendingTransfer> = new Map<number, PendingTransfer>();
      pending.set(2, completed);
      expect(completePendingTransfer(pending, 2, completed)).assertTrue();
      const unlink = beginUnlink(pending, 2);
      expect(unlink.status).assertEqual(0);
      expect(unlink.suppressSubmit).assertFalse();
      expect(classifyUnlinkTarget(undefined)).assertEqual('missing-or-completed');
    });

    it('cancels and clears pending non-control transfers when a client disconnects', 0, () => {
      const request: UsbIpSubmitRequest = testRequest(3, 0, 1);
      let cancelCount: number = 0;
      const pending: Map<number, PendingTransfer> = new Map<number, PendingTransfer>();
      const active: PendingTransfer = {
        request, endpointKey: '0:1', state: 'running', cancelled: false, control: false,
        cancel: (): boolean => { cancelCount++; return true; }
      };
      const control: PendingTransfer = {
        request: testRequest(4, 0, 0), endpointKey: 'control', state: 'running', cancelled: false, control: true,
        cancel: (): boolean => { cancelCount += 100; return true; }
      };
      pending.set(3, active);
      pending.set(4, control);
      cancelAndClearPendingTransfers(pending);
      expect(pending.size).assertEqual(0);
      expect(cancelCount).assertEqual(1);
      expect(active.cancelled).assertTrue();
      expect(active.state).assertEqual('complete');
      expect(control.cancelled).assertTrue();
      expect(control.state).assertEqual('complete');
    });

    it('retains a drained USB handle only when requested and quarantines an undrained handle', 0, () => {
      expect(classifyUsbHandleCloseDisposition(true, true)).assertEqual('retain');
      expect(classifyUsbHandleCloseDisposition(false, true)).assertEqual('release');
      expect(classifyUsbHandleCloseDisposition(true, false)).assertEqual('quarantine');
      expect(classifyUsbHandleCloseDisposition(false, false)).assertEqual('quarantine');
    });
  });
}
