import { BusinessError } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import usbipNative from 'libusbip_native.so';
import { UsbIpServer } from './UsbIpServer';
import { UsbIpServerEvent, UsbIpServerStatus } from '../usb/UsbModels';

const DOMAIN: number = 0x0000;
const TAG: string = 'LocalNetworkAddresses';

export type NetworkAddressFamily = 'IPv4' | 'IPv6';
export type NetworkAddressSource = 'getifaddrs' | 'connection';

export interface NetworkInterfaceAddress {
  key: string;
  family: NetworkAddressFamily;
  address: string;
  interfaceName: string;
  prefixLength: number;
  isLoopback: boolean;
  isUp: boolean;
  isRunning: boolean;
  source: NetworkAddressSource;
  /** True only if the running USB/IP listener has this address family; it does not prove firewall reachability. */
  listenerFamilySupported: boolean;
  serverReachable: boolean;
}

export interface NetworkAddressSnapshot {
  addresses: Array<NetworkInterfaceAddress>;
  updatedAt: number;
  source: 'getifaddrs+connection';
  limitations: Array<string>;
}

/** Uses the current server snapshot rather than enumeration-time reachability flags. */
export function addressMatchesListener(address: NetworkInterfaceAddress, status: UsbIpServerStatus): boolean {
  if (!status.running || !address.isUp || address.isLoopback || !status.listenerFamilies.includes(address.family)) {
    return false;
  }
  const configuredHost: string = status.host.trim().split('%')[0];
  if (configuredHost.length === 0 || configuredHost === '0.0.0.0' || configuredHost === '::') return true;
  const localAddress: string = address.address.split('%')[0];
  return configuredHost === localAddress;
}

interface NativeAddressRow {
  address: string;
  interfaceName: string;
  family: number;
  prefixLength: number;
  scopeId: number;
  isLoopback: boolean;
  isUp: boolean;
  isRunning: boolean;
};

const DEFAULT_LIMITATIONS: Array<string> = [
  '地址来自本机活动接口及NetworkKit已管理网络；系统路由、防火墙和对端可达性未探测。',
  '监听地址族由运行中的TCP socket实时核验；系统防火墙和Tailnet入站策略不会由USBArc自动修改。'
];

function isUnspecified(address: string, family: NetworkAddressFamily): boolean {
  const normalized: string = address.toLowerCase().split('%')[0];
  return family === 'IPv4' ? normalized === '0.0.0.0' : normalized === '::';
}

function isIPv6LinkLocal(address: string): boolean {
  const firstWord: string = address.toLowerCase().split('%')[0].split(':')[0];
  return firstWord.startsWith('fe8') || firstWord.startsWith('fe9') ||
    firstWord.startsWith('fea') || firstWord.startsWith('feb');
}

function withScope(address: string, interfaceName: string): string {
  if (isIPv6LinkLocal(address) && interfaceName.length > 0) {
    const baseAddress: string = address.split('%')[0];
    return `${baseAddress}%${interfaceName}`;
  }
  return address;
}

function makeAddressKey(family: NetworkAddressFamily, address: string, interfaceName: string): string {
  return `${family}|${interfaceName}|${address.toLowerCase()}`;
}

function makeAddress(
  family: NetworkAddressFamily,
  address: string,
  interfaceName: string,
  prefixLength: number,
  isLoopback: boolean,
  isUp: boolean,
  isRunning: boolean,
  source: NetworkAddressSource,
  listenerFamilies: Array<NetworkAddressFamily> = ['IPv4', 'IPv6']
): NetworkInterfaceAddress {
  const scopedAddress: string = family === 'IPv6' ? withScope(address, interfaceName) : address;
  const validHost: boolean = !isUnspecified(scopedAddress, family);
  const listenerFamilySupported: boolean = listenerFamilies.includes(family);
  return {
    key: makeAddressKey(family, scopedAddress, interfaceName),
    family,
    address: scopedAddress,
    interfaceName,
    prefixLength: Math.max(0, prefixLength),
    isLoopback,
    isUp,
    isRunning,
    source,
    listenerFamilySupported,
    serverReachable: validHost && listenerFamilySupported && !isLoopback && isUp
  };
}

/** Production normalization helper: adds IPv6 link-local scope and rejects only unspecified addresses. */
export function normalizeNetworkAddress(
  family: NetworkAddressFamily,
  address: string,
  interfaceName: string,
  prefixLength: number,
  isLoopback: boolean,
  isUp: boolean,
  isRunning: boolean,
  source: NetworkAddressSource,
  listenerFamilies: Array<NetworkAddressFamily> = ['IPv4', 'IPv6']
): NetworkInterfaceAddress | undefined {
  const normalizedLoopback: boolean = isLoopback || (family === 'IPv4'
    ? address.startsWith('127.') : address.toLowerCase().split('%')[0] === '::1');
  const normalized: NetworkInterfaceAddress = makeAddress(family, address, interfaceName, prefixLength,
    normalizedLoopback, isUp, isRunning, source, listenerFamilies);
  return isUnspecified(normalized.address, family) ? undefined : normalized;
}

/** Production deduplication helper keyed by address family, interface, and scoped address. */
export function mergeNetworkAddress(
  addresses: Map<string, NetworkInterfaceAddress>,
  candidate: NetworkInterfaceAddress
): void {
  const existing: NetworkInterfaceAddress | undefined = addresses.get(candidate.key);
  if (existing === undefined) {
    addresses.set(candidate.key, candidate);
    return;
  }
  if (existing.prefixLength === 0 && candidate.prefixLength > 0) existing.prefixLength = candidate.prefixLength;
  if (candidate.source === 'getifaddrs' && existing.source !== 'getifaddrs') {
    existing.source = candidate.source;
    existing.isLoopback = candidate.isLoopback;
    existing.isUp = candidate.isUp;
    existing.isRunning = candidate.isRunning;
  }
}

function errorCode(error: Object): number {
  const businessError: BusinessError = error as BusinessError;
  return businessError.code ?? -1;
}

function copyAddress(address: NetworkInterfaceAddress): NetworkInterfaceAddress {
  return {
    key: address.key,
    family: address.family,
    address: address.address,
    interfaceName: address.interfaceName,
    prefixLength: address.prefixLength,
    isLoopback: address.isLoopback,
    isUp: address.isUp,
    isRunning: address.isRunning,
    source: address.source,
    listenerFamilySupported: address.listenerFamilySupported,
    serverReachable: address.serverReachable
  };
}

export type NetworkAddressListener = (snapshot: NetworkAddressSnapshot) => void;

export class LocalNetworkAddresses {
  private snapshot: NetworkAddressSnapshot = {
    addresses: [], updatedAt: 0, source: 'getifaddrs+connection', limitations: DEFAULT_LIMITATIONS.slice()
  };
  private listeners: Set<NetworkAddressListener> = new Set<NetworkAddressListener>();
  private netConnection: connection.NetConnection | undefined = undefined;
  private serverUnsubscribe: (() => void) | undefined = undefined;
  private registerCallback: ((error: BusinessError | null | undefined) => void) | undefined = undefined;
  private refreshPromise: Promise<void> | undefined = undefined;
  private refreshRequested: boolean = false;

  async listAddresses(): Promise<NetworkAddressSnapshot> {
    await this.refresh();
    return this.copySnapshot();
  }

  subscribe(listener: NetworkAddressListener): () => void {
    this.listeners.add(listener);
    this.ensureNetworkMonitor();
    return (): void => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stopNetworkMonitor();
    };
  }

  async refresh(): Promise<void> {
    const activeRefresh: Promise<void> | undefined = this.refreshPromise;
    if (activeRefresh !== undefined) {
      this.refreshRequested = true;
      return activeRefresh;
    }
    const newRefresh: Promise<void> = this.refreshUntilClean();
    this.refreshPromise = newRefresh;
    let refreshAgain: boolean = false;
    try {
      await newRefresh;
    } finally {
      if (this.refreshPromise === newRefresh) this.refreshPromise = undefined;
      refreshAgain = this.refreshRequested;
      this.refreshRequested = false;
    }
    if (refreshAgain) await this.refresh();
  }

  private async refreshUntilClean(): Promise<void> {
    do {
      this.refreshRequested = false;
      await this.refreshInternal();
    } while (this.refreshRequested);
  }

  private copySnapshot(): NetworkAddressSnapshot {
    return {
      addresses: this.snapshot.addresses.map((address: NetworkInterfaceAddress): NetworkInterfaceAddress => copyAddress(address)),
      updatedAt: this.snapshot.updatedAt,
      source: this.snapshot.source,
      limitations: this.snapshot.limitations.slice()
    };
  }

  private async refreshInternal(): Promise<void> {
    const addresses: Map<string, NetworkInterfaceAddress> = new Map<string, NetworkInterfaceAddress>();
    const limitations: Array<string> = DEFAULT_LIMITATIONS.slice();
    const listenerFamilies: Array<NetworkAddressFamily> = UsbIpServer.getStatus().listenerFamilies.slice();
    if (listenerFamilies.length === 0) {
      limitations.push('USB/IP服务当前未运行，尚无活动监听socket。');
    } else if (!(listenerFamilies.includes('IPv4') && listenerFamilies.includes('IPv6'))) {
      limitations.push(`当前TCP监听仅覆盖${listenerFamilies.join('、')}。`);
    }
    try {
      const nativeRows: Array<NativeAddressRow> = usbipNative.getInterfaceAddresses();
      for (let index: number = 0; index < nativeRows.length; index++) {
        const row: NativeAddressRow = nativeRows[index];
        if (row.family !== 4 && row.family !== 6) continue;
        const family: NetworkAddressFamily = row.family === 4 ? 'IPv4' : 'IPv6';
        const info: NetworkInterfaceAddress | undefined = normalizeNetworkAddress(family, row.address,
          row.interfaceName, row.prefixLength, row.isLoopback, row.isUp, row.isRunning, 'getifaddrs', listenerFamilies);
        if (info !== undefined) mergeNetworkAddress(addresses, info);
      }
    } catch (error) {
      limitations.push(`本机接口枚举失败，错误码 ${errorCode(error as Object)}。`);
      hilog.warn(DOMAIN, TAG, 'getifaddrs enumeration failed. code=%{public}d', errorCode(error as Object));
    }

    try {
      const networks: Array<connection.NetHandle> = await connection.getAllNets();
      for (let index: number = 0; index < networks.length; index++) {
        const net: connection.NetHandle = networks[index];
        try {
          const properties: connection.ConnectionProperties = await connection.getConnectionProperties(net);
          for (let addrIndex: number = 0; addrIndex < properties.linkAddresses.length; addrIndex++) {
            const link: connection.LinkAddress = properties.linkAddresses[addrIndex];
            const netAddress: connection.NetAddress = link.address;
            const family: NetworkAddressFamily = (netAddress.family === 2 || netAddress.address.indexOf(':') >= 0)
              ? 'IPv6' : 'IPv4';
            const info: NetworkInterfaceAddress | undefined = normalizeNetworkAddress(family, netAddress.address,
              properties.interfaceName, link.prefixLength, false, true, true, 'connection', listenerFamilies);
            if (info !== undefined) mergeNetworkAddress(addresses, info);
          }
        } catch (error) {
          limitations.push(`网络 ${net.netId} 属性读取失败，错误码 ${errorCode(error as Object)}。`);
        }
      }
    } catch (error) {
      limitations.push(`NetworkKit网络列表读取失败，错误码 ${errorCode(error as Object)}。`);
      hilog.warn(DOMAIN, TAG, 'NetworkKit getAllNets failed. code=%{public}d', errorCode(error as Object));
    }

    const sorted: Array<NetworkInterfaceAddress> = Array.from(addresses.values());
    sorted.sort((left: NetworkInterfaceAddress, right: NetworkInterfaceAddress): number => {
      if (left.isLoopback !== right.isLoopback) return left.isLoopback ? 1 : -1;
      if (left.interfaceName !== right.interfaceName) return left.interfaceName.localeCompare(right.interfaceName);
      if (left.family !== right.family) return left.family === 'IPv4' ? -1 : 1;
      return left.address.localeCompare(right.address);
    });
    this.snapshot = { addresses: sorted, updatedAt: Date.now(), source: 'getifaddrs+connection', limitations };
    const published: NetworkAddressSnapshot = this.copySnapshot();
    this.listeners.forEach((listener: NetworkAddressListener): void => {
      try {
        listener(published);
      } catch (error) {
        hilog.warn(DOMAIN, TAG, 'Network address listener failed. code=%{public}d', errorCode(error as Object));
      }
    });
  }

  private ensureNetworkMonitor(): void {
    if (this.serverUnsubscribe === undefined) {
      this.serverUnsubscribe = UsbIpServer.subscribe((event: UsbIpServerEvent): void => {
        if (event.kind === 'status') void this.refresh();
      });
    }
    if (this.netConnection !== undefined) return;
    try {
      const monitor: connection.NetConnection = connection.createNetConnection();
      this.netConnection = monitor;
      monitor.on('netAvailable', (_handle: connection.NetHandle): void => { void this.refresh(); });
      monitor.on('netLost', (_handle: connection.NetHandle): void => { void this.refresh(); });
      monitor.on('netConnectionPropertiesChange', (_info: connection.NetConnectionPropertyInfo): void => {
        void this.refresh();
      });
      const registerCallback: (error: BusinessError | null | undefined) => void =
        (error: BusinessError | null | undefined): void => {
        if (error !== undefined) {
          hilog.warn(DOMAIN, TAG, 'Network monitor registration failed. code=%{public}d', error?.code ?? -1);
        }
        if (this.listeners.size > 0) void this.refresh();
      };
      this.registerCallback = registerCallback;
      monitor.register(registerCallback);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Network monitor setup failed. code=%{public}d', errorCode(error as Object));
    }
  }

  private stopNetworkMonitor(): void {
    const unsubscribeServer: (() => void) | undefined = this.serverUnsubscribe;
    this.serverUnsubscribe = undefined;
    if (unsubscribeServer !== undefined) unsubscribeServer();
    const monitor: connection.NetConnection | undefined = this.netConnection;
    const callback: ((error: BusinessError | null | undefined) => void) | undefined = this.registerCallback;
    this.netConnection = undefined;
    this.registerCallback = undefined;
    if (monitor === undefined || callback === undefined) return;
    try {
      monitor.unregister(callback);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Network monitor unregister failed. code=%{public}d', errorCode(error as Object));
    }
  }
}

export const sharedLocalNetworkAddresses: LocalNetworkAddresses = new LocalNetworkAddresses();
