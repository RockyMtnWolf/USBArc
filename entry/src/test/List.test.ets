import UsbIpProtocolTest from './UsbIpProtocol.test';
import UsbArcDevicePolicyTest from './UsbArcDevicePolicy.test';
import LocalNetworkAddressesTest from './LocalNetworkAddresses.test';

export default function testsuite() {
  UsbIpProtocolTest();
  UsbArcDevicePolicyTest();
  LocalNetworkAddressesTest();
}
