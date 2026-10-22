import { MessageEvents, worker } from '@kit.ArkTS';
import usbarcDdk from 'libusbarc_ddk.so';

interface DdkNativeProbeResult {
  status: number;
  value?: Object;
}

interface DdkNativeProbeDescriptor {
  vendorId: number;
  productId: number;
}

interface DdkReadOnlyProbeRequest {
  deviceId: string;
  vendorId: number;
  productId: number;
}

interface DdkReadOnlyProbeReply {
  initStatus: number;
  descriptorStatus: number;
  releaseStatus: number;
  matched: boolean;
}

const port = worker.workerPort;

port.onmessage = (event: MessageEvents): void => {
  const request: DdkReadOnlyProbeRequest = event.data as DdkReadOnlyProbeRequest;
  let initStatus: number = -5;
  let descriptorStatus: number = -5;
  let releaseStatus: number = -1;
  let matched: boolean = false;
  let acquiredInitialization: boolean = false;
  try {
    // Never release state owned by another Native environment in this process.
    if (usbarcDdk.isInitialized()) {
      initStatus = -16;
    } else {
      initStatus = usbarcDdk.init();
      acquiredInitialization = initStatus === 0;
      if (acquiredInitialization) {
        const descriptorResult: DdkNativeProbeResult = usbarcDdk.getDeviceDescriptor(request.deviceId);
        descriptorStatus = descriptorResult.status;
        if (descriptorStatus === 0 && descriptorResult.value !== undefined) {
          const descriptor: DdkNativeProbeDescriptor = descriptorResult.value as DdkNativeProbeDescriptor;
          matched = Number.isInteger(descriptor.vendorId) && Number.isInteger(descriptor.productId) &&
            descriptor.vendorId === request.vendorId && descriptor.productId === request.productId;
        }
      }
    }
  } catch (_error) {
    if (initStatus === 0) descriptorStatus = -5;
    else initStatus = -5;
  } finally {
    if (acquiredInitialization) {
      try {
        releaseStatus = usbarcDdk.release();
      } catch (_error) {
        releaseStatus = -5;
      }
    }
  }
  const reply: DdkReadOnlyProbeReply = { initStatus, descriptorStatus, releaseStatus, matched };
  port.postMessage(reply as Object);
  port.close();
};
