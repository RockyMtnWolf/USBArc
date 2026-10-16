# DDK backend scope

The DDK option is a separate backend, not a fallback to `usbManager`. It queries USB devices through DeviceManager, binds the selected device to the USBArc DriverExtensionAbility, checks the extension's initialized health, and maps it to one DDK opaque ID only when VID/PID resolution is unique. The app exposes a device as authorized only after those steps succeed. Devices outside the DriverExtensionAbility's declared USB VID/PID match list cannot be connected through this build.

Configuration descriptors are enumerated by USB descriptor index. The native bridge first reads the descriptor's `bConfigurationValue`, then calls `OH_Usb_GetConfigDescriptor` with that value. It separately reads `GET_CONFIGURATION`; the active configuration is placed first and used for claims. Switching to another configuration is unsupported because the DDK API surface used here has no verified configuration-switch operation. A request to keep the already active configuration is accepted as a no-op.

The current DDK path has explicit limits:

- ISO transfers, `URB_ZERO_PACKET`, force-claim, and cancellation of a running transfer return `-EOPNOTSUPP`.
- Pipe transfers through the RPC bridge are limited to 8,000 bytes. Oversized transfers return `-EMSGSIZE`; they are not truncated. Control requests are limited to 1,024 bytes and reject oversized `wLength` before submission.
- Pipe and control calls are synchronous inside the DriverExtension process with finite timeouts. ArkTS callers await the RPC asynchronously. No device throughput or latency claim is made.
- DDK does not expose a public negotiated-speed API. With the user's approved design, the app uses a temporary USBManager pipe only to query `USBDEVFS_GET_SPEED`, then closes it without claiming an interface or submitting USB transfers. This can require a separate OS USB authorization. Missing/ambiguous devices or an unreadable speed block DDK sharing instead of guessing from `bcdUSB`. Claims and data transfers still use DDK.
- Product, manufacturer and serial strings are read from the device's actual USB string descriptors, using one of its advertised language IDs. Unreadable optional strings remain empty; system hardware paths are never displayed as product names.
- Driver matching is limited to explicit USB VID and PID lists in `entry/src/main/module.json5`; wildcard matching is not configured. OpenHarmony's USB matcher tests VID and PID membership independently, so these two metadata lists describe a candidate cross-product rather than exact VID/PID pairs. The user still selects a concrete DeviceManager device before bind, and the backend rejects ambiguous DDK identity matches.
- The candidate metadata includes common USB serial/debug/storage IDs, including `0BDA:9210`; SanDisk and the RTL9210 bridge passed binding and descriptor queries, but storage interfaces were not claimed and no storage I/O was performed.

Compilation and pure helper tests validate descriptor parsing, endpoint direction mapping, RPC bounds, and error handling. Generic USB/IP interoperability, storage-device behavior, and real-device transfer operation remain unverified until tested with an approved, non-storage USB device on the target OS build.
