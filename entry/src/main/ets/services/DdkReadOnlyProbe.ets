import { ErrorEvent, MessageEvents, worker } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xDDA;
const TAG: string = 'DdkProbe';
const TIMEOUT_MS: number = 5000;
let readOnlyProbeWorkerActive: boolean = false;

export interface DdkReadOnlyProbeInput {
  busNum: number;
  devAddress: number;
  vendorId: number;
  productId: number;
}

export interface DdkReadOnlyProbeReply {
  initStatus: number;
  descriptorStatus: number;
  releaseStatus: number;
  matched: boolean;
}

interface DdkReadOnlyProbeWorkerRequest {
  deviceId: string;
  vendorId: number;
  productId: number;
}

/** USB DDK encodes bus and address in a uint64; Number arithmetic is exact within this validated range. */
export function makeDdkProbeDeviceId(busNum: number, devAddress: number): string | undefined {
  if (!Number.isInteger(busNum) || busNum < 0 || busNum > 0x1fffff ||
    !Number.isInteger(devAddress) || devAddress < 1 || devAddress > 127) return undefined;
  const deviceId: number = busNum * 4294967296 + devAddress;
  if (!Number.isSafeInteger(deviceId)) return undefined;
  return deviceId.toString(10);
}

function logProbeResult(reply: DdkReadOnlyProbeReply): void {
  hilog.info(DOMAIN, TAG,
    'DDK_READONLY_PROBE initStatus=%{public}d descriptorStatus=%{public}d releaseStatus=%{public}d matched=%{public}d',
    reply.initStatus, reply.descriptorStatus, reply.releaseStatus, reply.matched ? 1 : 0);
}

function failureReply(status: number): DdkReadOnlyProbeReply {
  return { initStatus: status, descriptorStatus: status, releaseStatus: -1, matched: false };
}

/** Launches a bounded, read-only DDK probe without delaying the original bind error. */
export function startDdkReadOnlyProbe(input: DdkReadOnlyProbeInput): boolean {
  if (readOnlyProbeWorkerActive) return false;
  const deviceId: string | undefined = makeDdkProbeDeviceId(input.busNum, input.devAddress);
  if (deviceId === undefined) {
    logProbeResult(failureReply(-22));
    return true;
  }

  let probeWorker: worker.ThreadWorker;
  readOnlyProbeWorkerActive = true;
  try {
    probeWorker = new worker.ThreadWorker('entry/ets/workers/DdkReadOnlyProbeWorker.ets', {
      name: 'USBArc-DDK-readonly-probe'
    });
  } catch (_error) {
    readOnlyProbeWorkerActive = false;
    logProbeResult(failureReply(-5));
    return true;
  }

  let completed: boolean = false;
  let timedOut: boolean = false;
  const timeout: number = setTimeout((): void => {
    timedOut = true;
    logProbeResult(failureReply(-110));
  }, TIMEOUT_MS);
  const finish = (reply: DdkReadOnlyProbeReply): void => {
    if (completed) return;
    if (!completed) {
      completed = true;
      clearTimeout(timeout);
    }
    logProbeResult(reply);
    if (!timedOut) readOnlyProbeWorkerActive = false;
  };

  probeWorker.onmessage = (event: MessageEvents): void => {
    const reply: DdkReadOnlyProbeReply = event.data as DdkReadOnlyProbeReply;
    finish(reply);
  };
  probeWorker.onerror = (_error: ErrorEvent): void => {
    finish(failureReply(-5));
  };
  probeWorker.onexit = (code: number): void => {
    if (code === 0) {
      if (!completed && !timedOut) finish(failureReply(-5));
      readOnlyProbeWorkerActive = false;
    } else {
      finish(failureReply(-5));
    }
  };
  try {
    const request: DdkReadOnlyProbeWorkerRequest = {
      deviceId,
      vendorId: input.vendorId,
      productId: input.productId
    };
    probeWorker.postMessage(request);
  } catch (_error) {
    finish(failureReply(-5));
    probeWorker.terminate();
    readOnlyProbeWorkerActive = false;
  }
  return true;
}
