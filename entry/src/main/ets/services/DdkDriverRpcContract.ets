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
    data: readBytes(source, 'data')
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
