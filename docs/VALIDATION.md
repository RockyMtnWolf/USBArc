# Validation Record

Last updated: 2026-10-17 (Asia/Shanghai)

## Latest CH340 iteration

The tested functional package has 51/51 passing Local Tests, a successful debug build, and lint with 0 errors / 4 existing warnings. It was installed at `192.168.112.143:37727` after the user stopped the service. On 2026-10-17, the user requested vendor `RockyMtnWolf`; that metadata-only revision built successfully and its packaged `module.json` was checked. Subsequent clicks and task/service starts are performed by the user.

The user connected only a dock and CH340, then shared CH340 in DDK mode. Windows `usbip.exe list` correctly identified `1A86:7523` at `ddk-4294967299`; raw DEVLIST confirmed genuine full-speed enum `2` from the approved read-only USBManager speed query. Screenshot inspection confirmed the device product name is now `USB Serial`, rather than a hardware path. DDK transfers and interface claims remain separate from this temporary speed-query pipe.

The first Windows attach returned port 1, then disconnected before a serial device appeared. The app reported `SUBMIT device id does not match imported device`. Root traced this to comparing an unsigned on-wire ID with a signed ArkTS bitwise result for logical bus 57198. The current package compares unsigned IDs, with a production regression for `0xdf6e0001` and mismatch cases.

After the ID correction, Windows enumerated `USB-SERIAL CH340 (COM3)` with PnP status `OK` and `DEVPKEY_Device_ProblemCode=0`. A pre-existing local test attachment reconnected first, explaining one additional attach attempt's `Device not available` response while the device was already owned. Root stopped only this target's retry attempt and detached port 1, then a fresh `attach --once` succeeded on port 1, still at Full Speed (12 Mbps), with COM3 `OK`. The reviewed maximized screenshot `evidence/matebook-ch340-com3-20261016.png` shows one shared device, one client and `客户端使用中`. After cleanup detach, the card correctly returned to `共享中`. No serial port was opened and no UART payload was sent.

The dock exposes two logical hub IDs, `2109:0817` and `2109:2817`. The first conservative hub filter retained them because a matching USBManager hub classification was unavailable. The final filter also recognizes class 09 from a strictly validated, VID/PID-consistent DeviceManager hardware identifier; this format is observed on the MateBook, not an SDK-guaranteed encoding. Unknown formats remain visible. Root reviewed `evidence/matebook-ch340-hubs-hidden-final-20261016.png`: only one CH340 card remains, detected/shared/client counts are each 1, the product name is `USB Serial`, and its state is `客户端使用中`. A fresh local attach on this final functional build again produced COM3 with status OK.

The DDK pipe transport now uses one Ashmem attachment per atomic URB, capped at 1 MiB; 64 KiB, short-IN and cleanup paths have helper-test coverage. No large hardware transfer or serial payload test has been performed. No storage device was imported or used for data I/O.

The following section records the earlier dual-stack baseline; its empty DEVLIST and storage-metadata observations are historical, not the current CH340 inventory.

This record distinguishes local USB/IP listener checks from remote transport and USB device operations. DDK binding and read-only descriptor/configuration queries succeeded; storage interfaces were not claimed and no storage device was imported, attached, or used for data I/O.

## Environment and build

| Item | Observed state |
|---|---|
| Target | HUAWEI MateBook Pro S, 2in1, HarmonyOS API 26; HDC target `100.116.69.50:37727` |
| App snapshot used for the 11:32 device observation | Main app build based on checkpoint `0845c6e` with DDK integration; user selected USB DDK and automatic authorization. The UI listed two devices, `0781:5591` and `0BDA:9210`, both “driver connected / idle”; shared count was 0. |
| Final source verification | Local Test 39/39; official lint 0 errors and 4 custom-component reuse warnings; full signed debug build succeeded at 11:33. |
| Final installation | The signed HAP with DDK health checks and address fallback installed and launched successfully; CLI Smoke PASS. Runtime layout and the reviewed screenshot confirm actual addresses and both listener labels. |

## Results

| Area | Result | Evidence and limits |
|---|---|---|
| Protocol, device-policy, network-address, and DDK Local Tests | Pass, 39/39 | Latest main-tree Local Test report. Includes the listener-label regression where stale `serverReachable=false` is overridden by the live server state and actual listener-family list. |
| ArkTS lint | Pass with warnings | 0 errors; 4 warnings recommend `@Builder` instead of custom components. |
| Full debug build | Pass | Final build at 11:33 succeeded and produced a signed HAP. |
| MateBook device snapshot | Pass, read-only | Two devices were listed in the USB DDK UI, both idle and driver-connected; shared count was 0. This did not test transfer, import, claim, or storage access. |
| Listener socket families | Pass, local observation | While the test service was running on TCP port 3240, `netstat` showed `[::]:3240` listening; IPv4-mapped connections were accepted. This records the bound socket family, not remote IPv6 reachability over every interface. |
| IPv4 loopback DEVLIST | Pass | A system `toybox nc` probe sent `01 11 80 05 00 00 00 00` to `127.0.0.1:3240` and received exactly `01 11 00 05 00 00 00 00 00 00 00 00` (successful DEVLIST, zero devices). |
| IPv6 loopback DEVLIST | Pass | The same 8-byte request to numeric `::1:3240` received the same exact 12-byte empty DEVLIST response. An independently compiled native probe was denied execution and was not counted as successful; the successful evidence is from the system `toybox nc` fallback. |
| Windows IPv4 USB/IP DEVLIST | Pass, zero devices | The fragmented DEVLIST probe to `100.116.69.50:3240` completed successfully with device count 0. No IMPORT was sent. |
| Windows Tailnet IPv6 | Not connected | A connection attempt to `fd7a:115c:a1e0::8a3b:4533:3240` timed out. This is a Tailnet IPv6 transport result, not evidence that the MateBook's native IPv6 listener failed; local `::1` listener and DEVLIST checks passed. |
| DDK binding and metadata | Pass for the two listed devices | Driver-connected state is published only after binding, initialization health, unambiguous opaque ID matching, descriptor reads and GET_CONFIGURATION succeed. This does not prove claim or transfer compatibility. |
| Interface claim, import, attach, or device I/O | Not tested | No USB/IP IMPORT or attach was sent. No storage interface was claimed and no storage data was read or written. |
| Screenshot review | Pass for current address correction | Root reviewed `evidence/matebook-active-network-20261016.png`: maximized USBArc, actual virnic4 IPv4 and scoped IPv6, both listening labels, two equal idle DDK cards and shared count 0. |

## Address display note

At the time of the latest address check, `wlan0` had no address. The active virtual interface reported IPv4 `10.47.56.82`. Do not reuse older screenshots or addresses as current network state. The approved display behavior is to prefer `wlan0` addresses and, when it has none, show the actual default physical interface selected from NetworkKit/interface metadata with its interface name; it must not guess an address.

## Protocol scope

Tests call exported production functions and compare fixed wire bytes as well as state transitions; they do not rely only on encoder/decoder round trips. The protocol suite covers network byte order, fragmented and coalesced frames, transfer bounds, non-ISO packet markers `0` and `0xffffffff`, invalid direction/endpoint and ISO rejection, the USB GET_DESCRIPTOR setup packet's little-endian fields, DEVLIST/IMPORT descriptors, response headers, pending-transfer cleanup, and UNLINK cancellation races. The protocol reference is the [Linux kernel USB/IP specification](https://docs.kernel.org/usb/usbip_protocol.html).

The runtime network checks were limited to empty DEVLIST requests. The earlier service was stopped before installing the final package, then restarted with automatic sharing off for the final check. Both numeric loopbacks again returned the exact successful empty header, and the Windows fragmented IPv4 probe passed. Service was left running with shared count 0. After the user confirmed the new HDC address `192.168.112.143:37727`, both the Windows fragmented DEVLIST probe and the actual `usbip.exe list -r 192.168.112.143` command succeeded; no devices were exported.

Subsequent device clicks, backend selection, service/task starts and sharing actions are performed by the user. The agent performs local USB/IP tests and read-only screenshot review.
