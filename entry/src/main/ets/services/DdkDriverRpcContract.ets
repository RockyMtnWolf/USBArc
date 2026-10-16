export const MAX_DDK_SHARED_TRANSFER_BYTES: number = 1048576;

export interface DdkDriverWireRequest {
  operation: string;
  deviceId: string;
  interfaceNumber: number;
  handle: string;
  alternateSetting: number;
  configurationIndex: number;
  endpointAddress: number;
  timeoutMs: number;
  setup: Array<number>;
  data: Array<number>;
  sharedMemoryTransfer: boolean;
  sharedMemoryLength: number;
}

export interface DdkDriverWireReply {
  status: number;
  error?: string;
  initialized?: boolean;
  resourcesReleased?: boolean;
  value?: Object;
  actualLength?: number;
  data?: Array<number>;
}

function readInteger(source: Record<string, Object>, key: string): number {
  const value: Object | undefined = source[key];
  if (value === undefined) return 0;
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    throw new Error(`DDK RPC field ${key} must be a non-negative integer`);
  }
  return value as number;
}

function readString(source: Record<string, Object>, key: string): string {
  const value: Object | undefined = source[key];
  if (value === undefined) return '';
  if (typeof value !== 'string') throw new Error(`DDK RPC field ${key} must be a string`);
  return value as string;
}

function readBytes(source: Record<string, Object>, key: string): Array<number> {
  const value: Object | undefined = source[key];
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new Error(`DDK RPC field ${key} must be a byte array`);
  const result: Array<number> = [];
  (value as Array<Object>).forEach((item: Object): void => {
    if (typeof item !== 'number' || !Number.isInteger(item) || item < 0 || item > 255) {
      throw new Error(`DDK RPC field ${key} contains an invalid byte`);
    }
    result.push(item as number);
  });
  return result;
}

function readBoolean(source: Record<string, Object>, key: string): boolean {
  const value: Object | undefined = source[key];
  if (value === undefined) return false;
  if (typeof value !== 'boolean') throw new Error(`DDK RPC field ${key} must be a boolean`);
  return value as boolean;
}

/** Validates the explicit, out-of-line pipe payload contract used by both RPC endpoints. */
export function validateDdkSharedTransfer(operation: string, sharedMemoryTransfer: boolean,
  sharedMemoryLength: number, sharedMemorySize: number, inlineDataLength: number): void {
  if (operation !== 'pipeTransfer' || !sharedMemoryTransfer || inlineDataLength !== 0 ||
    !Number.isInteger(sharedMemoryLength) || sharedMemoryLength < 0 ||
    sharedMemoryLength > MAX_DDK_SHARED_TRANSFER_BYTES ||
    sharedMemorySize !== Math.max(1, sharedMemoryLength)) {
    throw new Error('DDK shared-memory transfer has invalid operation or bounds');
  }
}

/** Validates a pipe result before its bytes are copied into the shared region. */
export function validateDdkSharedTransferResult(isInput: boolean, capacity: number, actualLength: number,
  responseData: Array<number>): boolean {
  if (!Number.isInteger(capacity) || capacity < 0 || capacity > MAX_DDK_SHARED_TRANSFER_BYTES ||
    !Number.isInteger(actualLength) || actualLength < 0 || actualLength > capacity) return false;
  for (let index: number = 0; index < responseData.length; index++) {
    if (!Number.isInteger(responseData[index]) || responseData[index] < 0 || responseData[index] > 255) return false;
  }
  return isInput ? responseData.length === actualLength : responseData.length === 0;
}

/** Ensures mappings are removed and the handle is closed, even when the action fails. */
export function cleanupDdkAshmem(unmap: () => void, close: () => void, mapped: boolean): void {
  let cleanupFailure: Error | undefined = undefined;
  if (mapped) {
    try {
      unmap();
    } catch (error) {
      cleanupFailure = error instanceof Error ? error : new Error('Failed to unmap DDK Ashmem');
    }
  }
  try {
    close();
  } catch (error) {
    if (cleanupFailure === undefined) {
      cleanupFailure = error instanceof Error ? error : new Error('Failed to close DDK Ashmem');
    }
  }
  if (cleanupFailure !== undefined) throw cleanupFailure;
}

export function parseDdkDriverWireRequest(raw: string): DdkDriverWireRequest {
  const source: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
  const operation: string = readString(source, 'operation');
  if (operation.length === 0) throw new Error('DDK RPC operation is required');
  return {
    operation,
    deviceId: readString(source, 'deviceId'),
    interfaceNumber: readInteger(source, 'interfaceNumber'),
    handle: readString(source, 'handle'),
    alternateSetting: readInteger(source, 'alternateSetting'),
    configurationIndex: readInteger(source, 'configurationIndex'),
    endpointAddress: readInteger(source, 'endpointAddress'),
    timeoutMs: readInteger(source, 'timeoutMs'),
    setup: readBytes(source, 'setup'),
    data: readBytes(source, 'data'),
    sharedMemoryTransfer: readBoolean(source, 'sharedMemoryTransfer'),
    sharedMemoryLength: readInteger(source, 'sharedMemoryLength')
  };
}

/** Converts NAPI's native `{status,value}` object to the flat RPC reply contract. */
export function normalizeNativeDdkReply(nativeValue: Object): DdkDriverWireReply {
  if (typeof nativeValue === 'number') return { status: nativeValue as number };
  const fields: Record<string, Object> = nativeValue as Record<string, Object>;
  const statusValue: Object | undefined = fields['status'];
  if (typeof statusValue !== 'number' || !Number.isInteger(statusValue)) {
    return { status: -5, error: 'DDK native response did not contain an integer status' };
  }
  const reply: DdkDriverWireReply = { status: statusValue as number };
  const value: Object | undefined = fields['value'];
  if (value !== undefined) reply.value = value;
  const actualLength: Object | undefined = fields['actualLength'];
  if (typeof actualLength === 'number' && Number.isInteger(actualLength)) reply.actualLength = actualLength as number;
  const data: Object | undefined = fields['data'];
  if (Array.isArray(data)) reply.data = data as Array<number>;
  return reply;
}
