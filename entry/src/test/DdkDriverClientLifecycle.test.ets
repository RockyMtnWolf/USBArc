import { describe, it, expect } from '@ohos/hypium';
import {
  DdkDeviceDescriptor,
  DdkDriverClient,
  DdkDriverClientError,
  DdkRpcReply,
  DdkRpcRequest,
  DdkSystemDeviceInfo,
  DdkWorkerRequestTransport,
  makeDdkPhysicalDeviceId
} from '../main/ets/services/DdkDriverClient';

class FakeDdkWorkerTransport implements DdkWorkerRequestTransport {
  readonly requests: Array<string> = [];
  readonly devices: Array<DdkSystemDeviceInfo>;
  initialized: boolean = false;
  failFirstRelease: boolean = false;
  private releaseCalls: number = 0;

  constructor(devices: Array<DdkSystemDeviceInfo>) {
    this.devices = devices;
  }

  async request(request: DdkRpcRequest): Promise<DdkRpcReply> {
    this.requests.push(request.operation);
    if (request.operation === 'init') {
      this.initialized = true;
      return { requestId: request.requestId, status: 0, initialized: true };
    }
    if (request.operation === 'release') {
      this.initialized = false;
      return { requestId: request.requestId, status: 0, initialized: false, resourcesReleased: true };
    }
    if (request.operation === 'getDeviceDescriptor') {
      const descriptor: DdkDeviceDescriptor = {
        id: request.deviceId,
        bytes: [],
        vendorId: 0x0951,
        productId: 0x1666,
        deviceClass: 0,
        deviceSubClass: 0,
        deviceProtocol: 0,
        bcdUsb: 0x0200,
        bcdDevice: 0x0100,
        maxPacketSize0: 64,
        configurationCount: 1
      };
      return { requestId: request.requestId, status: 0, value: descriptor as Object };
    }
    if (request.operation === 'claimInterface') {
      return { requestId: request.requestId, status: 0, value: `claim-${request.deviceId}` as Object };
    }
    if (request.operation === 'pipeTransfer') {
      return { requestId: request.requestId, status: -110, error: 'simulated pipe timeout' };
    }
    if (request.operation === 'releaseInterface') {
      this.releaseCalls++;
      if (this.failFirstRelease && this.releaseCalls === 1) {
        return { requestId: request.requestId, status: -5, error: 'simulated release failure' };
      }
      return { requestId: request.requestId, status: 0 };
    }
    return { requestId: request.requestId, status: 0 };
  }
}

function systemDevice(busNum: number, devAddress: number): DdkSystemDeviceInfo {
  const deviceId: number | undefined = makeDdkPhysicalDeviceId(busNum, devAddress);
  return { deviceId: deviceId ?? -1, vendorId: 0x0951, productId: 0x1666, description: 'Kingston DataTraveler' };
}

export default function DdkDriverClientLifecycleTest() {
  describe('DdkDriverClientLifecycle', () => {
    it('binds duplicate VID PID devices by exact bus and address IDs', 0, async () => {
      const first: DdkSystemDeviceInfo = systemDevice(2, 2);
      const second: DdkSystemDeviceInfo = systemDevice(3, 7);
      const fake: FakeDdkWorkerTransport = new FakeDdkWorkerTransport([first, second]);
      const client: DdkDriverClient = new DdkDriverClient(fake, (): Array<DdkSystemDeviceInfo> => [first, second]);

      await client.bind(first.deviceId);
      await client.bind(second.deviceId);
      const firstIds: Array<string> = await client.getDriverDeviceIds(first.deviceId);
      const secondIds: Array<string> = await client.getDriverDeviceIds(second.deviceId);

      expect(firstIds.length).assertEqual(1);
      expect(firstIds[0]).assertEqual(first.deviceId.toString());
      expect(secondIds[0]).assertEqual(second.deviceId.toString());
    });

    it('retains a claim after failed I/O and failed release until a real release succeeds', 0, async () => {
      const device: DdkSystemDeviceInfo = systemDevice(2, 2);
      const fake: FakeDdkWorkerTransport = new FakeDdkWorkerTransport([device]);
      fake.failFirstRelease = true;
      const client: DdkDriverClient = new DdkDriverClient(fake, (): Array<DdkSystemDeviceInfo> => [device]);
      await client.bind(device.deviceId);
      const claim: string = await client.claimInterface(device.deviceId, device.deviceId.toString(), 0);

      let transferFailed: boolean = false;
      try {
        await client.pipeTransfer(device.deviceId, claim, 0x81, [0], 25);
      } catch (_error) {
        transferFailed = true;
      }
      expect(transferFailed).assertTrue();

      let releaseFailed: boolean = false;
      try {
        await client.unbind(device.deviceId);
      } catch (error) {
        releaseFailed = error instanceof DdkDriverClientError;
      }
      expect(releaseFailed).assertTrue();
      await client.unbind(device.deviceId);
      expect(fake.requests.filter((operation: string): boolean => operation === 'releaseInterface').length)
        .assertEqual(2);
      await client.unbindAll();
      expect(fake.initialized).assertFalse();
    });
  });
}
