/** Structured request shared by the UI-side client and the DDK owner worker. */
export interface DdkRpcRequest {
  requestId: number;
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

export interface DdkRpcReply {
  requestId: number;
  status: number;
  error?: string;
  initialized?: boolean;
  resourcesReleased?: boolean;
  value?: Object;
  actualLength?: number;
  data?: Array<number>;
}
