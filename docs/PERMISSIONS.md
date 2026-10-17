# Permissions and access requirements

USBArc's manifest permissions, per-device USB authorization, background tasks, and TCP listening control different capabilities. Granting one does not grant the others.

## Manifest permissions

The app requests the following permissions in its entry module:

| Permission | API 26 SDK classification | Why USBArc declares it |
| --- | --- | --- |
| `ohos.permission.INTERNET` | `normal`, `system_grant` | Opens the USB/IP TCP listener and uses network APIs. It does not by itself authorize inbound traffic through a system firewall or another app's network policy. |
| `ohos.permission.GET_NETWORK_INFO` | `normal`, `system_grant` | Reads active network and local interface information for the address display. |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | `normal`, `system_grant` | Required when the user asks the system background task manager for a continuous task. The system may decline or cancel a task. |
| `ohos.permission.ACCESS_EXTENSIONAL_DEVICE_DRIVER` | `normal`, `system_grant` | Required by DeviceManager's external-device query and binding APIs used by the DDK path. The API 26 SDK classifies this as a normal permission; this permission alone does not grant USB DDK access. |
| `ohos.permission.ACCESS_DDK_USB` | `system_basic`, `system_grant`; restricted ACL in the API 26 SDK | Grants the DriverExtensionAbility access to USB DDK APIs when the permission is approved and included in the signing profile. |

These classifications are taken from the API 26 SDK permission definitions used for this project. Permission availability and profile requirements can vary by HarmonyOS release and developer account; check the SDK and current Huawei documentation when targeting another version.

The current combined HAP unconditionally declares both `ACCESS_DDK_USB` and `ACCESS_EXTENSIONAL_DEVICE_DRIVER`, even though USB DDK is only an optional runtime backend. Installation of this combined package with an ordinary signing profile has not been verified, including when USBManager is selected. The USBManager API itself does not require the DDK ACL, but selecting it does not remove manifest declarations from the package. Without the approved DDK ACL, a manager-only source build would need to remove the DDK permission and driver extension. That manager-only configuration has not been tested.

## Optional USB DDK backend

USBManager is the default backend and the USBManager API does not require the DDK ACL. USB DDK is optional at runtime. Selecting DDK does not fall back to USBManager when DDK setup is unavailable. Note that the current combined HAP still declares the DDK permission and driver extension unconditionally; ordinary-profile installation of that package has not been verified. See the package-level note above.

The USB DDK APIs are restricted to the DriverExtensionAbility lifecycle and require matching ACL permission. For this app, the signing profile must be associated with the bundle and include approved `ohos.permission.ACCESS_DDK_USB`. Merely declaring the name in `module.json5`, creating a generic debug profile, or signing with an unrelated profile is not sufficient. The developer account must first be approved for the ACL and then create a profile that includes it. See Huawei's [DriverExtensionAbility guide](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V13/driverextensionability-V13) and [debug profile instructions](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-debug-profile-0000002248181278).

`ACCESS_EXTENSIONAL_DEVICE_DRIVER` is also required for the peripheral-device client APIs. The API 26 SDK lists it as `normal` and `system_grant`, rather than as the restricted DDK ACL. Huawei's driver guide still requires the app to declare it. Do not confuse it with `ACCESS_DDK_USB` or the newer `ACCESS_DDK_DRIVERS` permission.

DDK's current USB speed query briefly opens a read-only USBManager pipe after per-device USB authorization, obtains the speed, and closes that pipe. It sends no transfer through USBManager and does not claim the device there; DDK performs device claims and USB/IP data transfers. The speed query still requires the user-authorized USBManager right. If it cannot obtain a known speed, USBArc will not export the device.

## USB device authorization

USBManager device rights are requested at runtime with the system USB authorization flow. This is not one of the manifest permission names listed above. A user must confirm the system request when the app does not already have the right. Enabling automatic authorization requests only lets USBArc ask the system when a matching device appears; it cannot approve or bypass the system prompt. Denial does not authorize sharing.

In DDK mode, USBArc binds the selected peripheral to its DriverExtensionAbility and checks that the extension initialized the device successfully. This is a different path from USBManager authorization and still depends on the DDK ACL. A reported connected/authorized state is shown only after the selected backend confirms its required operation.

## Background task requests

USBArc declares the `dataTransfer` and `taskKeeping` background modes and the `KEEP_BACKGROUND_RUNNING` permission. The user can explicitly request task keeping or a simulated data-transfer task. `taskKeeping` is intended for 2-in-1 devices. The simulated data-transfer mode downloads no file and does not invent progress. These requests do not guarantee that an app stays alive indefinitely; the system can cancel a task, and USBArc respects that cancellation. See the official [Background Task Manager API reference](https://developer.huawei.com/consumer/en/doc/harmonyos-references-V14/js-apis-resourceschedule-backgroundtaskmanager-V14).

## TCP listener and inbound policy

`INTERNET` allows the app to use networking APIs; it is not a system firewall approval. USBArc asks the operating system to bind the user-selected TCP address and port, then reports success only after the socket is actually listening. A system firewall, network profile, or MeshArc/Tailscale inbound policy may still block connections. When using MeshArc, allow USBArc's selected TCP port in MeshArc separately. USBArc cannot grant or inspect another app's or the system's inbound authorization.

USB/IP does not provide authentication or encryption. Use the listener only on a network you trust or behind a separately secured tunnel. Do not treat a local bind confirmation as a firewall rule or as protection from untrusted clients.

## References

- [OpenHarmony USB DDK guidelines](https://github.com/openharmony/docs/blob/master/en/application-dev/device/driver/usb-ddk-guidelines.md)
- [Huawei Peripheral Driver Development](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V13/driverextensionability-V13)
- [Huawei USB service overview](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V14/usb-overview-V14)
- [Huawei API 26 permission definitions](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-v5/permissions-for-all-V5)
- [Huawei debug profile and ACL instructions](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-debug-profile-0000002248181278)
