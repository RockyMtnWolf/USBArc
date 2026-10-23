<div align="center">

**English** | [简体中文](README_zh.md)

# USBArc

<img src="AppScope/resources/base/media/app_icon.png" width="96" alt="USBArc app icon">

**A native USB/IP server for HarmonyOS 2-in-1 devices.**

> **DDK access requirement:** The combined HAP declares `ohos.permission.ACCESS_DDK_USB`, which requires an approved signing-profile ACL for the DDK backend. Installation of this combined package with an ordinary profile remains unverified, even in USBManager mode. The current experimental DDK backend calls NDK APIs directly from an ArkTS Worker; it is not a `DriverExtensionAbility` implementation. The official DriverExtension guide does not establish support for this Worker architecture or compatibility across devices. USBManager itself does not require the DDK ACL; a manager-only build would omit `ACCESS_DDK_USB`, and that configuration has not been tested.

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-API%2026-007DFF?style=for-the-badge)](https://developer.huawei.com/consumer/en/)
[![Device class](https://img.shields.io/badge/Device-2--in--1-3DA5D9?style=for-the-badge)](#compatibility)
[![Protocol](https://img.shields.io/badge/Protocol-USB%2FIP-0A7EA4?style=for-the-badge)](https://github.com/vadimgrn/usbip-win2)
[![Optional DDK](https://img.shields.io/badge/USB%20DDK-Optional-6B7280?style=for-the-badge)](#permissions)

[Source repository](https://github.com/RockyMtnWolf/USBArc) · [简体中文](README_zh.md)

</div>

---

USBArc shares USB peripherals connected to a HarmonyOS 2-in-1 computer over USB/IP 1.1.1. On a Windows client, use [usbip-win2](https://github.com/vadimgrn/usbip-win2) to list and attach an exported device. USBArc is an independent project and does not include MeshArc, Tailscale, or VPN functionality.

## Features

- **Two explicit device backends:** USBManager is the ordinary-app path. The optional DDK backend requires an authorized signing profile and uses direct NDK calls from an ArkTS Worker; it remains experimental and never silently falls back to USBManager.
- **User-controlled access:** request USB system authorization manually or enable automatic requests. Automatic mode only asks the system and never approves a device silently. Automatic sharing can target all devices or saved VID/PID rules.
- **Desktop workflow:** adaptive device cards, live server and client state, tray controls, and close-to-tray behavior.
- **Network visibility:** shows detected local IPv4 and IPv6 addresses separately from the configured bind address. The UI reports the address families actually bound by the server.
- **Optional background task requests:** task keeping and a simulated data-transfer task. The simulated mode performs no download and reports no invented progress; the system may cancel either task.
- **Appearance:** follows the system theme or uses a selected light/dark theme, with an optional local image background.

The intended peripherals include USB storage, J-Link, ST-Link, USB-to-TTL adapters, and CDC serial devices. Compatibility depends on the device, interface descriptors, driver/backend, and host OS; the list is not a guarantee that every model or transfer type works.

## Compatibility and test status

| Item | Support |
| --- | --- |
| Minimum and target API | HarmonyOS API 26 |
| Declared device type | 2-in-1 only |
| USB/IP client used for validation | Windows `usbip-win2` |
| USB/IP protocol | 1.1.1 |
| Isochronous transfers | Not supported |

Earlier DDK testing on a HUAWEI MateBook Pro S with API 26 exercised a CH340 USB-to-serial adapter and an ST-Link V2. Windows reported both devices with PnP `ProblemCode 0`; the user also confirmed a successful STM32CubeProgrammer read through ST-Link. An initial ST-Link attach timeout was observed and remains under investigation. Those runs predate the current Worker-based DDK implementation and do not validate it. They cover only the devices and setup used at the time.

In a separate USBManager storage test this round, sharing failed with Force Claim off. The user enabled Force Claim and sharing succeeded; after turning it off, sharing succeeded again. This supports an earlier interface-ownership conflict in that case. Only the server-side sharing stage was verified; there was no Windows client attach, disk access, or file transfer, so USB storage data transfer remains unverified.

The current Worker-based DDK build has since been confirmed by the user on real hardware to connect to and share the Kingston 0951:1666 storage device and a Realtek RTL9210B enclosure at the USBArc server. This confirms only the device connection and server-side sharing stage for those devices. A USB/IP client attach, disk I/O, file transfer, and broader device compatibility remain unverified.

DDK mode reports USB speed only after a temporary, read-only USBManager pipe is opened with USB authorization; that pipe is closed immediately, and USB claiming and data transfers remain on DDK. If this speed query is unavailable, the device is not exported because the tested Windows client rejects an unknown speed.

## Install

Check [GitHub Releases](https://github.com/RockyMtnWolf/USBArc/releases) for unsigned HAP packages and release notes. A device generally requires an accepted signature before installation. Sign the package with credentials you are authorized to use. Do not share signing keys or provisioning profiles.

The USBManager API itself does not require the DDK ACL. However, the current combined HAP still requests `ACCESS_DDK_USB`, so installation with an ordinary profile has not been verified, even if USBManager mode is selected. To use the optional DDK backend, the signing profile must include the approved `ohos.permission.ACCESS_DDK_USB` ACL. A manager-only build would omit that permission; USBArc does not currently register a `DriverExtensionAbility`, and this manager-only configuration has not been tested.

## Build

Install DevEco Studio with the HarmonyOS API 26 SDK and DevEco CLI. For a fresh checkout without local project settings, initialize them from the tracked example:

```powershell
Copy-Item build-profile.example.json5 build-profile.json5
```

Configure local signing only if you need to install the build on a device. Keep signing settings local and out of commits. Then build from the repository root:

```powershell
devecocli build --modules entry --build-mode debug
```

To assemble a release `.app` package:

```powershell
devecocli build --product default --build-mode release --assemble-type assembleApp
```

The source repository does not provide signing credentials. A locally built package without signing is not necessarily installable on a device. For DDK testing, use a profile authorized for the DDK ACL.

## Connect from Windows

Start USBArc's server, authorize the device, and select it for sharing. Then use the address and bus ID shown by USBArc:

```powershell
usbip.exe list -r <USBArc-address>
usbip.exe attach -r <USBArc-address> -b <bus-id>
```

The default port is `3240`. USBArc listens only after the user confirms the selected port and the operating system successfully binds the socket. When connecting through MeshArc, allow the port in MeshArc's inbound policy as well; USBArc cannot grant system firewall or another app's inbound permission. USB/IP itself does not provide authentication or encryption. Use a trusted network or a separately secured tunnel, and do not expose the server to an untrusted network.

## Screenshots

![USBArc device list](image/01-devices.png)

![USBArc settings](image/02-settings.png)

![USBArc device list in dark theme](image/03-devices-dark.png)

## Permissions

USB device authorization, DDK access, background tasks, and network listening are separate controls. The current manifest requests four permissions:

| Permission | Protection | Purpose |
| --- | --- | --- |
| `ohos.permission.INTERNET` | Normal, system-grant | USB/IP networking. Does not grant firewall or inbound-network approval. |
| `ohos.permission.GET_NETWORK_INFO` | Normal, system-grant | Read active network and local address information. |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | Normal, system-grant | Request supported background tasks; the system can decline or cancel them. |
| `ohos.permission.ACCESS_DDK_USB` | System-basic, system-grant, restricted ACL | USB DDK access; requires an approved signing-profile ACL. |

These classifications are from the API 26 SDK. The manifest no longer requests `ACCESS_EXTENSIONAL_DEVICE_DRIVER`. The experimental DDK backend calls NDK APIs directly from an ArkTS Worker rather than registering a `DriverExtensionAbility`; the official DriverExtension guide describes a separate workflow and does not establish support for this Worker architecture or compatibility across devices. The DDK path still requires its approved `ACCESS_DDK_USB` ACL; limited server-side hardware results are described above. USBManager authorization is a separate per-device system request, not a manifest permission. A manager-only build would omit `ACCESS_DDK_USB`; that configuration has not been tested. Background-task confirmation and TCP inbound/firewall policy are also separate from manifest permissions. See [Privacy Policy](https://privacy.rockymtnwolf.ccwu.cc/usbarc/) or contact [smartwolf@stu.xidian.edu.cn](mailto:smartwolf@stu.xidian.edu.cn).

## License

USBArc is released under the [BSD 3-Clause License](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party notices.

## References

- [HarmonyOS USB service overview](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V14/usb-overview-V14)
- [Peripheral Driver Development and signing (DriverExtensionAbility workflow; separate from USBArc's Worker path)](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V13/driverextensionability-V13)
- [USB DDK guidelines (OpenHarmony)](https://github.com/openharmony/docs/blob/master/en/application-dev/device/driver/usb-ddk-guidelines.md)
- [Requesting a debug profile and ACL permissions](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-debug-profile-0000002248181278)
- [usbip-win2](https://github.com/vadimgrn/usbip-win2)
