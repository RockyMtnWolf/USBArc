import { describe, it, expect } from '@ohos/hypium';
import {
  addressMatchesListener,
  mergeNetworkAddress,
  NetworkInterfaceAddress,
  normalizeNetworkAddress
} from '../main/ets/services/LocalNetworkAddresses';
import { UsbIpServerStatus } from '../main/ets/usb/UsbModels';

export default function LocalNetworkAddressesTest() {
  describe('LocalNetworkAddressesTest', () => {
    it('updates both listener labels when addresses were enumerated before service startup', 0, () => {
      const ipv4: NetworkInterfaceAddress = normalizeNetworkAddress(
        'IPv4', '192.0.2.10', 'wlan0', 24, false, true, true, 'getifaddrs', []) as NetworkInterfaceAddress;
      const ipv6: NetworkInterfaceAddress = normalizeNetworkAddress(
        'IPv6', '2001:db8::10', 'wlan0', 64, false, true, true, 'getifaddrs', []) as NetworkInterfaceAddress;
      const status: UsbIpServerStatus = {
        running: false, host: '0.0.0.0', port: 3240, clientCount: 0,
        sharedDeviceIds: [], occupiedDeviceIds: [], listenerFamilies: [], lastError: ''
      };
      expect(ipv4.serverReachable).assertFalse();
      expect(ipv6.serverReachable).assertFalse();
      expect(addressMatchesListener(ipv4, status)).assertFalse();
      status.running = true;
      status.listenerFamilies = ['IPv4', 'IPv6'];
      expect(addressMatchesListener(ipv4, status)).assertTrue();
      expect(addressMatchesListener(ipv6, status)).assertTrue();
      status.host = '192.0.2.10';
      expect(addressMatchesListener(ipv4, status)).assertTrue();
      expect(addressMatchesListener(ipv6, status)).assertFalse();
      status.host = '192.0.2.11';
      expect(addressMatchesListener(ipv4, status)).assertFalse();
      status.host = '::';
      status.listenerFamilies = ['IPv6'];
      expect(addressMatchesListener(ipv4, status)).assertFalse();
      expect(addressMatchesListener(ipv6, status)).assertTrue();
      status.running = false;
      expect(addressMatchesListener(ipv6, status)).assertFalse();
    });

    it('keeps live IPv4 interfaces separate and marks only active non-loopback IPv4 as listener-supported', 0, () => {
      const wlan: NetworkInterfaceAddress | undefined = normalizeNetworkAddress(
        'IPv4', '192.168.112.143', 'wlan0', 24, false, true, true, 'getifaddrs', ['IPv4']);
      const hotspot: NetworkInterfaceAddress | undefined = normalizeNetworkAddress(
        'IPv4', '172.17.1.1', 'ancowlan0', 24, false, true, true, 'connection', ['IPv4']);
      expect(wlan === undefined).assertFalse();
      expect(hotspot === undefined).assertFalse();
      const wlanAddress: NetworkInterfaceAddress = wlan as NetworkInterfaceAddress;
      const hotspotAddress: NetworkInterfaceAddress = hotspot as NetworkInterfaceAddress;
      expect(wlanAddress.address).assertEqual('192.168.112.143');
      expect(wlanAddress.listenerFamilySupported).assertTrue();
      expect(wlanAddress.serverReachable).assertTrue();
      expect(hotspotAddress.interfaceName).assertEqual('ancowlan0');
      expect(hotspotAddress.listenerFamilySupported).assertTrue();
      const inactive: NetworkInterfaceAddress | undefined = normalizeNetworkAddress(
        'IPv4', '192.168.112.144', 'wlan1', 24, false, false, false, 'getifaddrs', ['IPv4']);
      expect((inactive as NetworkInterfaceAddress).serverReachable).assertFalse();
      const merged: Map<string, NetworkInterfaceAddress> = new Map<string, NetworkInterfaceAddress>();
      mergeNetworkAddress(merged, wlanAddress);
      mergeNetworkAddress(merged, hotspotAddress);
      expect(merged.size).assertEqual(2);
    });

    it('preserves IPv6 scope and derives listener reachability from the actual socket families', 0, () => {
      const linkLocal: NetworkInterfaceAddress | undefined = normalizeNetworkAddress(
        'IPv6', 'fe80::abcd', 'wlan0', 64, false, true, true, 'getifaddrs', ['IPv4']);
      expect(linkLocal === undefined).assertFalse();
      const address: NetworkInterfaceAddress = linkLocal as NetworkInterfaceAddress;
      expect(address.address).assertEqual('fe80::abcd%wlan0');
      expect(address.key).assertEqual('IPv6|wlan0|fe80::abcd%wlan0');
      expect(address.listenerFamilySupported).assertFalse();
      expect(address.serverReachable).assertFalse();
      const alreadyScoped: NetworkInterfaceAddress | undefined = normalizeNetworkAddress(
        'IPv6', 'fe80::1%wlan0', 'wlan0', 64, false, true, true, 'connection', ['IPv4', 'IPv6']);
      expect((alreadyScoped as NetworkInterfaceAddress).address).assertEqual('fe80::1%wlan0');
      expect((alreadyScoped as NetworkInterfaceAddress).listenerFamilySupported).assertTrue();
      const global: NetworkInterfaceAddress | undefined = normalizeNetworkAddress(
        'IPv6', '2001:db8::8', 'wlan0', 64, false, true, true, 'getifaddrs', ['IPv4', 'IPv6']);
      expect((global as NetworkInterfaceAddress).address).assertEqual('2001:db8::8');
      expect((global as NetworkInterfaceAddress).listenerFamilySupported).assertTrue();
      expect((global as NetworkInterfaceAddress).serverReachable).assertTrue();
    });

    it('filters unspecified addresses while retaining loopback addresses for display', 0, () => {
      expect(normalizeNetworkAddress('IPv4', '0.0.0.0', 'wlan0', 0, false, true, true,
        'getifaddrs', ['IPv4']) === undefined).assertTrue();
      expect(normalizeNetworkAddress('IPv6', '::', 'wlan0', 0, false, true, true,
        'getifaddrs', ['IPv4', 'IPv6']) === undefined).assertTrue();
      const ipv4Loopback: NetworkInterfaceAddress | undefined = normalizeNetworkAddress(
        'IPv4', '127.0.0.1', 'lo', 8, true, true, true, 'getifaddrs', ['IPv4', 'IPv6']);
      const ipv6Loopback: NetworkInterfaceAddress | undefined = normalizeNetworkAddress(
        'IPv6', '::1', 'lo', 128, true, true, true, 'getifaddrs', ['IPv4', 'IPv6']);
      expect(ipv4Loopback === undefined).assertFalse();
      expect(ipv6Loopback === undefined).assertFalse();
      expect((ipv4Loopback as NetworkInterfaceAddress).isLoopback).assertTrue();
      expect((ipv4Loopback as NetworkInterfaceAddress).serverReachable).assertFalse();
      expect((ipv6Loopback as NetworkInterfaceAddress).isLoopback).assertTrue();
      expect((ipv6Loopback as NetworkInterfaceAddress).serverReachable).assertFalse();
    });

    it('deduplicates matching native and NetworkKit rows, merges prefix length, and preserves distinct interfaces', 0, () => {
      const fromNetworkKit: NetworkInterfaceAddress | undefined = normalizeNetworkAddress(
        'IPv4', '192.168.112.143', 'wlan0', 0, false, true, true, 'connection', ['IPv4']);
      const fromNative: NetworkInterfaceAddress | undefined = normalizeNetworkAddress(
        'IPv4', '192.168.112.143', 'wlan0', 24, false, true, true, 'getifaddrs', ['IPv4']);
      const sameIpOtherInterface: NetworkInterfaceAddress | undefined = normalizeNetworkAddress(
        'IPv4', '192.168.112.143', 'ancowlan0', 24, false, true, true, 'getifaddrs', ['IPv4']);
      const merged: Map<string, NetworkInterfaceAddress> = new Map<string, NetworkInterfaceAddress>();
      mergeNetworkAddress(merged, fromNetworkKit as NetworkInterfaceAddress);
      mergeNetworkAddress(merged, fromNative as NetworkInterfaceAddress);
      mergeNetworkAddress(merged, sameIpOtherInterface as NetworkInterfaceAddress);
      expect(merged.size).assertEqual(2);
      const wlan: NetworkInterfaceAddress | undefined = merged.get('IPv4|wlan0|192.168.112.143');
      expect(wlan === undefined).assertFalse();
      expect((wlan as NetworkInterfaceAddress).prefixLength).assertEqual(24);
      expect((wlan as NetworkInterfaceAddress).source).assertEqual('getifaddrs');
      expect(merged.has('IPv4|ancowlan0|192.168.112.143')).assertTrue();
    });
  });
}
