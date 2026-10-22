import UsbIpProtocolTest from './UsbIpProtocol.test';
import UsbArcDevicePolicyTest from './UsbArcDevicePolicy.test';
import LocalNetworkAddressesTest from './LocalNetworkAddresses.test';
import DdkDriverClientHelpersTest from './DdkDriverClientHelpers.test';
import UsbNegotiatedSpeedTest from './UsbNegotiatedSpeed.test';
import UsbHubClassificationTest from './UsbHubClassification.test';
import UsbDeviceMetadataTest from './UsbDeviceMetadata.test';

export default function testsuite() {
  UsbIpProtocolTest();
  UsbArcDevicePolicyTest();
  LocalNetworkAddressesTest();
  DdkDriverClientHelpersTest();
  UsbNegotiatedSpeedTest();
  UsbHubClassificationTest();
  UsbDeviceMetadataTest();
}
