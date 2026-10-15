export const USBIP_VERSION: number = 0x0111;
export const OP_REQ_IMPORT: number = 0x8003;
export const OP_REP_IMPORT: number = 0x0003;
export const OP_REQ_DEVLIST: number = 0x8005;
export const OP_REP_DEVLIST: number = 0x0005;
export const USBIP_CMD_SUBMIT: number = 0x00000001;
export const USBIP_CMD_UNLINK: number = 0x00000002;
export const USBIP_RET_SUBMIT: number = 0x00000003;
export const USBIP_RET_UNLINK: number = 0x00000004;
export const USBIP_DIR_OUT: number = 0;
export const USBIP_DIR_IN: number = 1;
export const USBIP_NON_ISO_PACKETS: number = 0xffffffff;
export const MAX_TRANSFER_BYTES: number = 16 * 1024 * 1024;
export const MAX_INTERFACES: number = 64;
export const MAX_DEVICE_COUNT: number = 64;

export interface UsbIpSubmitRequest {
  seqnum: number;
  devid: number;
  direction: number;
  endpoint: number;
  transferFlags: number;
  transferLength: number;
  startFrame: number;
  numberOfPackets: number;
  interval: number;
  setup: Uint8Array;
  payload: Uint8Array;
}

export interface UsbIpUnlinkRequest {
  seqnum: number;
  targetSeqnum: number;
}

export interface UsbIpSetupPacket {
  requestType: number;
  request: number;
  value: number;
  index: number;
  length: number;
}

export function readU16(data: Uint8Array, offset: number): number {
  return data[offset] * 256 + data[offset + 1];
}

export function readLE16(data: Uint8Array, offset: number): number {
  return data[offset] + data[offset + 1] * 256;
}

export function readU32(data: Uint8Array, offset: number): number {
  return (data[offset] * 0x1000000 + data[offset + 1] * 0x10000 + data[offset + 2] * 0x100 + data[offset + 3]) >>> 0;
}

export function writeU16(data: Uint8Array, offset: number, value: number): void {
  data[offset] = (value >>> 8) & 0xff;
  data[offset + 1] = value & 0xff;
}

export function writeU32(data: Uint8Array, offset: number, value: number): void {
  data[offset] = (value >>> 24) & 0xff;
  data[offset + 1] = (value >>> 16) & 0xff;
  data[offset + 2] = (value >>> 8) & 0xff;
  data[offset + 3] = value & 0xff;
}

export function writeString(data: Uint8Array, offset: number, size: number, value: string): void {
  // USB/IP path and busid fields are ASCII identifiers; do not rely on unavailable Web TextEncoder APIs.
  const count: number = Math.min(value.length, size - 1);
  for (let i: number = 0; i < count; i++) {
    const char: number = value.charCodeAt(i);
    data[offset + i] = char <= 0x7f ? char : 0x3f;
  }
}

export function readString(data: Uint8Array, offset: number, size: number): string {
  let end: number = offset;
  const max: number = Math.min(data.length, offset + size);
  while (end < max && data[end] !== 0) {
    end++;
  }
  let value: string = '';
  for (let i: number = offset; i < end; i++) value += String.fromCharCode(data[i]);
  return value;
}

export function concatBytes(left: Uint8Array, right: Uint8Array): Uint8Array {
  const result: Uint8Array = new Uint8Array(left.length + right.length);
  result.set(left, 0);
  result.set(right, left.length);
  return result;
}

/** Returns the exact length of the next frame, or zero while the TCP stream is incomplete. */
export function nextFrameLength(buffer: Uint8Array): number {
  if (buffer.length < 4) {
    return 0;
  }
  const command: number = readU32(buffer, 0);
  if (command === USBIP_CMD_SUBMIT || command === USBIP_CMD_UNLINK) {
    if (buffer.length < 48) {
      return 0;
    }
    if (command === USBIP_CMD_UNLINK) {
      return 48;
    }
    const transferLength: number = readU32(buffer, 24);
    if (transferLength > MAX_TRANSFER_BYTES) {
      throw new Error(`USB/IP transfer length ${transferLength} exceeds limit ${MAX_TRANSFER_BYTES}`);
    }
    const direction: number = readU32(buffer, 12);
    if (direction !== USBIP_DIR_OUT && direction !== USBIP_DIR_IN) {
      throw new Error(`Invalid USB/IP direction ${direction}`);
    }
    const numberOfPackets: number = readU32(buffer, 32);
    // USB/IP marks every non-ISO request with UINT32_MAX. Do not interpret it as packet count.
    if (numberOfPackets !== 0 && numberOfPackets !== USBIP_NON_ISO_PACKETS) {
      throw new Error('Isochronous USB/IP transfers are not supported by this release');
    }
    const endpoint: number = readU32(buffer, 16);
    if (endpoint > 15) throw new Error(`Invalid USB endpoint number ${endpoint}`);
    const payloadLength: number = direction === USBIP_DIR_OUT ? transferLength : 0;
    const frameLength: number = 48 + payloadLength;
    return buffer.length < frameLength ? 0 : frameLength;
  }
  if (buffer.length < 8) {
    return 0;
  }
  const version: number = readU16(buffer, 0);
  const command16: number = readU16(buffer, 2);
  if (version !== USBIP_VERSION) {
    throw new Error(`Unsupported USB/IP version 0x${version.toString(16)}`);
  }
  if (command16 === OP_REQ_DEVLIST) {
    return 8;
  }
  if (command16 === OP_REQ_IMPORT) {
    return buffer.length < 40 ? 0 : 40;
  }
  throw new Error(`Unsupported USB/IP command 0x${command16.toString(16)}`);
}

export function parseSubmit(frame: Uint8Array): UsbIpSubmitRequest {
  if (frame.length < 48) throw new Error('USB/IP SUBMIT header is incomplete');
  const direction: number = readU32(frame, 12);
  const endpoint: number = readU32(frame, 16);
  const transferLength: number = readU32(frame, 24);
  if (direction !== USBIP_DIR_OUT && direction !== USBIP_DIR_IN) throw new Error(`Invalid USB/IP direction ${direction}`);
  if (endpoint > 15) throw new Error(`Invalid USB endpoint number ${endpoint}`);
  if (transferLength > MAX_TRANSFER_BYTES) throw new Error(`USB/IP transfer length ${transferLength} exceeds limit ${MAX_TRANSFER_BYTES}`);
  const expectedLength: number = 48 + (direction === USBIP_DIR_OUT ? transferLength : 0);
  if (frame.length !== expectedLength) throw new Error(`SUBMIT frame length ${frame.length} does not match expected ${expectedLength}`);
  const numberOfPackets: number = readU32(frame, 32);
  if (numberOfPackets !== 0 && numberOfPackets !== USBIP_NON_ISO_PACKETS) {
    throw new Error('Isochronous USB/IP transfers are not supported by this release');
  }
  return {
    seqnum: readU32(frame, 4),
    devid: readU32(frame, 8),
    direction,
    endpoint,
    transferFlags: readU32(frame, 20),
    transferLength,
    startFrame: readU32(frame, 28),
    numberOfPackets,
    interval: readU32(frame, 36),
    setup: frame.slice(40, 48),
    payload: frame.slice(48)
  };
}

export function parseUnlink(frame: Uint8Array): UsbIpUnlinkRequest {
  return { seqnum: readU32(frame, 4), targetSeqnum: readU32(frame, 20) };
}

/** USB setup packets use little-endian 16-bit fields, unlike USB/IP's big-endian headers. */
export function parseSetupPacket(setup: Uint8Array): UsbIpSetupPacket {
  if (setup.length !== 8) throw new Error('USB setup packet must be exactly 8 bytes');
  return {
    requestType: setup[0], request: setup[1], value: readLE16(setup, 2),
    index: readLE16(setup, 4), length: readLE16(setup, 6)
  };
}

export function makeOpHeader(reply: number, status: number, extraLength: number): Uint8Array {
  const data: Uint8Array = new Uint8Array(8 + extraLength);
  writeU16(data, 0, USBIP_VERSION);
  writeU16(data, 2, reply);
  writeU32(data, 4, status);
  return data;
}

export function makeBasic(command: number, seqnum: number): Uint8Array {
  const data: Uint8Array = new Uint8Array(48);
  writeU32(data, 0, command);
  writeU32(data, 4, seqnum);
  // USB/IP server response basic fields devid, direction, endpoint are always zero.
  return data;
}
