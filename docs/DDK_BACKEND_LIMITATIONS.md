# DDK backend scope

The DDK option is a separate backend, not a fallback to `usbManager`. It queries USB devices through DeviceManager, binds the selected device to the USBArc DriverExtensionAbility, checks the extension's initialized health, and maps it to one DDK opaque ID only when VID/PID resolution is unique. The app exposes a device as authorized only after those steps succeed. Devices outside the DriverExtensionAbility's declared USB VID/PID match list cannot be connected through this build.

Configuration descriptors are enumerated by USB descriptor index. The native bridge first reads the descriptor's `bConfigurationValue`, then calls `OH_Usb_GetConfigDescriptor` with that value. It separately reads `GET_CONFIGURATION`; the active configuration is placed first and used for claims. Switching to another configuration is unsupported because the DDK API surface used here has no verified configuration-switch operation. A request to keep the already active configuration is accepted as a no-op.

The current DDK path has explicit limits:

- ISO transfers, `URB_ZERO_PACKET`, force-claim, and cancellation of a running transfer return `-EOPNOTSUPP`.
- Data transfers through the RPC bridge are limited to 8,000 bytes. Oversized transfers return `-EMSGSIZE`; they are not truncated.
- Pipe and control calls are synchronous inside the DriverExtension process with finite timeouts. ArkTS callers await the RPC asynchronously. No device throughput or latency claim is made.
- USB speed and serial number are reported as unknown/empty because the selected public APIs do not provide verified values in this implementation.
- Driver matching is limited to explicit USB VID and PID lists in `entry/src/main/module.json5`; wildcard matching is not configured. OpenHarmony's USB matcher tests VID and PID membership independently, so these two metadata lists describe a candidate cross-product rather than exact VID/PID pairs. The user still selects a concrete DeviceManager device before bind, and the backend rejects ambiguous DDK identity matches.
- The candidate metadata includes common USB serial/debug/storage IDs, including `0BDA:9210`; storage IDs are enabled for driver matching but have not been bound or used for I/O in validation.

Compilation and pure helper tests validate descriptor parsing, endpoint direction mapping, RPC bounds, and error handling. Generic USB/IP interoperability, storage-device behavior, and real-device transfer operation remain unverified until tested with an approved, non-storage USB device on the target OS build.
