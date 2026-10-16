# Validation Record

Last updated: 2026-10-15

This record separates source-level protocol evidence, DevEco build evidence, device behavior, and Windows USB/IP interoperability. A passing build does not imply device or client interoperability.

## Environment

| Item | Observed state |
|---|---|
| DevEco Studio | 26.0.0.851 |
| HarmonyOS SDK | API 26, 26.0.0.105 Release |
| DevEco CLI | 1.3.4 |
| Connected target | HUAWEI MateBook Pro S, 2in1, API 26; HDC connection confirmed |
| USB/IP Windows client | `C:\Program Files\USBip\usbip.exe` is installed; version 0.9.8.1; `list --help` confirms remote DEVLIST support |
| USB/IP host driver | Present and OK: USBip 3.X Emulated Host Controller; provider USBIP-WIN2, version 12.1.30.403, service `usbip2_ude` |
| Debug signing | USBArc-specific debug signing generation succeeded through `devecocli signature generate --product default`; local `build-profile.json5` is ignored by Git |

The Windows host's latest read-only inventory showed no CH343, CH340, CP2102, CH347, ST-Link, or USB mass-storage device; the host's four listed disks are fixed internal disks. A read-only MateBook inventory showed CH340 (`1A86:7523`), CP2102 (`10C4:EA60`), CH343 (`1A86:55D3`), CH347-family (`1A86:55DB`), ST-Link V2 (`0483:3748`), ST-Link V3 (`0483:374E`), SanDisk storage (`0781:5591`), and USBasp (`16C0:05DC`). These are on the HarmonyOS MateBook, not the Windows host. The current app card reports the CH343 as authorized; no transfer, claim, share, attach, or write has been performed. An earlier CH343 permission request returned `true` while the card still showed unauthorized and no system dialog was visible. That discrepancy later cleared, but its cause remains unknown; the request result alone did not establish a grant, and no source-backed root cause has been confirmed.

A read-only `ifconfig -a` on the MateBook reported `wlan0` UP/RUNNING at `192.168.112.143/24` (the current HDC route), `ancowlan0` UP/RUNNING at `172.17.1.1/24`, and loopback at `127.0.0.1`; `p2p0` and `chba0` were UP without an IPv4 `inet` field. No interface output included an `inet6` address. The device's `ip` command was unavailable and `/proc/net/if_inet6` was denied, so the IPv6 inventory is inconclusive. The candidate app has not yet displayed the new address service; after deployment, its address list will be compared against these real IPv4 values and the native/API IPv6 results.

## Results

| Area | Result | Evidence / limit |
|---|---|---|
| Independent protocol, device-policy, and local-network tests against production functions | Pass, 22/22 | `entry/.test/default/intermediates/test/coverage_data/test_result.txt`: 15 `UsbIpProtocolTest` + 3 `UsbArcDevicePolicyTest` + 4 `LocalNetworkAddressesTest`, 0 failures/errors. The network tests cover production IPv4/IPv6 normalization, link-local scope, unspecified-address filtering, loopback retention, and duplicate rows from native/NetworkKit sources. |
| `devecocli check lint entry --product default` | Pass with one warning | 0 errors; one style warning in `components/UsbDeviceCard.ets` preferring `@Builder` over a custom component. |
| `devecocli build --modules entry --build-mode debug` | Pass for current deployed address UI snapshot | Native CMake/Ninja and ArkTS completed; HAP was signed with USBArc-specific local debug credentials. This snapshot predates the latest request to limit the address section to `wlan0`, change background-task controls, remove Exit, and auto-refresh on USB attach/detach; rebuild/review is pending those changes. Warnings include CMake minimum-version deprecation, future NAPI verification for `libusbip_native.so`, and ArkTS exception-handling advisories. |
| MateBook install and UI view | Pass, current installed snapshot | `devecocli run --skip-build` installed and launched `io.github.rockymtnwolf.usbarc/EntryAbility`; safe maximized main screenshot: `docs/evidence/matebook-main-addresses-20261015.png`. It showed 3 IPv4 rows and 4 IPv6 rows, with IPv6 marked display-only because the server listens on IPv4. The UI was approved; next snapshot will show only `wlan0` per the latest requirement. Settings screenshot is intentionally pending the new UI revision. |
| USB device authorization and descriptor export | CH343 authorized in UI; export not tested | The current card reports CH343 authorized after the earlier request/refresh discrepancy. This is authorization state only; no descriptor export or USB claim/share was attempted. The original mismatch's cause is unknown. |
| MateBook USB enumeration | Pass, read-only | Eight devices appeared on the current main page, including USBasp. Inventory only; SanDisk was not imported or attached; ST-Link devices were not flashed; no serial data was sent. |
| Windows `usbip list` / DEVLIST | Not tested | Client and driver are installed. Physical devices are available on the MateBook but absent from the Windows host; the USB/IP server has not yet been verified with a shared device. A fragmented raw DEVLIST probe is available in `scripts/tests/probe-fragmented-devlist.ps1`. |
| Windows IMPORT / attach / actual device I/O / detach | Not tested | MateBook devices are present, but authorization/share has not been confirmed. The SanDisk disk remains excluded from import/attach; ST-Link devices will not be flashed and no serial payload will be sent. |
| Background task, tray registration, window-close recovery | Pending | Must be observed on the MateBook after visual review; short observation does not establish permanent background survival. |

## Protocol checks

The independent suite calls exported production code and compares behavior with the [Linux kernel USB/IP protocol specification](https://docs.kernel.org/usb/usbip_protocol.html). It includes fixed wire-byte expectations as well as stream and session behavior, so it does not rely only on encode/decode round trips.

The test source covers network byte order, fragmented and coalesced TCP frames, maximum and oversized transfer lengths, non-ISO `number_of_packets` values `0` and `0xffffffff` (`-1`), invalid direction/endpoint and ISO rejection, the actual GET_DESCRIPTOR setup packet's little-endian fields, DEVLIST/IMPORT descriptor offsets, server response basic-header fields, pending-transfer disconnect cleanup, and UNLINK queued/active/completion races. Successful cancellation returns `USBIP_RET_UNLINK` status `-104` and suppresses the original submit reply; an already-completed or absent target returns status `0`. Queued control transfers are cancelled before execution; running control transfers return `-EOPNOTSUPP`. A final source-level case checks that USB/IP header direction drives transfer direction even when `URB_DIR_IN` is absent from `transferFlags`.

