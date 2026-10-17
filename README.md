<div align="center">

**English** | [简体中文](README_zh.md)

# USBArc

<img src="AppScope/resources/base/media/app_icon.png" width="96" alt="USBArc app icon">

**A native USB/IP server for HarmonyOS 2-in-1 devices.**

> **DDK signing requirement:** USB DDK is an optional runtime backend, but the current combined HAP unconditionally declares both `ohos.permission.ACCESS_DDK_USB` and `ohos.permission.ACCESS_EXTENSIONAL_DEVICE_DRIVER`. Installation of this combined package with an ordinary profile, even when using USBManager mode, has not been verified. Selecting USBManager does not remove the DDK ACL requirement. Without an approved DDK ACL, a manager-only source build would need to remove the DDK permission and driver extension; that configuration has not been tested.

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-API%2026-007DFF?style=for-the-badge)](https://developer.huawei.com/consumer/en/)
[![Device class](https://img.shields.io/badge/Device-2--in--1-3DA5D9?style=for-the-badge)](#compatibility)
[![Protocol](https://img.shields.io/badge/Protocol-USB%2FIP-0A7EA4?style=for-the-badge)](https://github.com/vadimgrn/usbip-win2)
[![Optional DDK](https://img.shields.io/badge/USB%20DDK-Optional-6B7280?style=for-the-badge)](docs/PERMISSIONS.md)

[Source repository](https://github.com/RockyMtnWolf/USBArc) · [简体中文](README_zh.md)

</div>

---

USBArc shares USB peripherals connected to a HarmonyOS 2-in-1 computer over USB/IP 1.1.1. On a Windows client, use [usbip-win2](https://github.com/vadimgrn/usbip-win2) to list and attach an exported device. USBArc is an independent project and does not include MeshArc, Tailscale, or VPN functionality.

## Features

- **Two explicit device backends:** USBManager is the ordinary-app path. USB DDK is an optional backend that requires an authorized signing profile; it never silently falls back to USBManager.
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

Recent testing on a HUAWEI MateBook Pro S with API 26 exercised the DDK path with a CH340 USB-to-serial adapter and an ST-Link V2. Windows reported both devices with PnP `ProblemCode 0`; the user also confirmed a successful STM32CubeProgrammer read through ST-Link. An initial ST-Link attach timeout was observed and remains under investigation. These results cover those devices and that setup only. USB storage and other device models, other HarmonyOS device types, and broad transfer compatibility have not been established.

DDK mode reports USB speed only after a temporary, read-only USBManager pipe is opened with USB authorization; that pipe is closed immediately, and USB claiming and data transfers remain on DDK. If this speed query is unavailable, the device is not exported because the tested Windows client rejects an unknown speed.

## Install

Check [GitHub Releases](https://github.com/RockyMtnWolf/USBArc/releases) for unsigned HAP packages and release notes. A device generally requires an accepted signature before installation. Sign the package with credentials you are authorized to use. Do not share signing keys or provisioning profiles.

The USBManager API itself does not require the DDK ACL. However, the current combined HAP declares `ACCESS_DDK_USB` and the driver extension unconditionally, and installation with an ordinary profile has not been verified—even if USBManager mode is selected. To use the optional DDK backend, the signing profile must include the approved `ohos.permission.ACCESS_DDK_USB` ACL. Without that ACL, remove the DDK permission and driver extension from the source before building a manager-only package; this manager-only configuration has not been tested. See [Permissions and signing](docs/PERMISSIONS.md).

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

USB device authorization, optional DDK access, background task requests, and network listening are separate controls. Their requirements and limits are documented in [docs/PERMISSIONS.md](docs/PERMISSIONS.md).

## License

USBArc is released under the [BSD 3-Clause License](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party notices.

## References

- [HarmonyOS USB service overview](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V14/usb-overview-V14)
- [Peripheral Driver Development and signing](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V13/driverextensionability-V13)
- [USB DDK guidelines (OpenHarmony)](https://github.com/openharmony/docs/blob/master/en/application-dev/device/driver/usb-ddk-guidelines.md)
- [Requesting a debug profile and ACL permissions](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-debug-profile-0000002248181278)
- [usbip-win2](https://github.com/vadimgrn/usbip-win2)
