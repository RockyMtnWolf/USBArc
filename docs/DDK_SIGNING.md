# USBArc DDK 签名准备

正式接入采用同包方案：UIAbility 与 DriverExtensionAbility 一同放入 USBArc，包名为 `io.github.rockymtnwolf.usbarc`。这是根据用户已批准的 Profile 与官方模块能力确定的方案，避免额外申请独立驱动包。独立 `ddk-driver/` 工程保留作开发验证，暂不用于正式部署。

| 包 | Bundle ID | 用途 |
|---|---|---|
| USBArc | `io.github.rockymtnwolf.usbarc` | 界面、USB/IP 服务、DDK 驱动及客户端 |
| USBArc DDK（独立开发工程） | `io.github.rockymtnwolf.usbarc.ddk` | 单独构建验证，正式同包部署不使用此包 |

2026-10-15 已使用 SignedCms 解码用户提供的 `USB_DDK_TestDebug.p7b`，只读取必要字段：

- `bundle-info.bundle-name` 为主应用包名。
- `acls.allowed-acls` 包含 `ohos.permission.ACCESS_DDK_USB`。
- 未发现 `ACCESS_EXTENSIONAL_DEVICE_DRIVER` 或 `ACCESS_DDK_DRIVERS`，未发现 `app-services-capabilities`。
- 用户提供的 `.cer.cer` 是三张 PEM 证书组成的证书链，包含开发者叶证书；不能把链中的第一张根证书当成签名叶证书。
- 后续已通过官方 `hap-sign-tool verify-profile` 与 `verify-app` 验证：现有本地签名实际生成的 HAP 开发者叶证书与用户 Profile 中的开发者叶证书指纹一致。可复用现有私钥及其加密签名配置，将 Profile 路径切换到用户提供的文件。

当前 Profile 不能直接签署另一个包名的独立驱动，但包名与正式同包方案一致。后续准备：

1. 主 entry 同时声明真实 DriverExtensionAbility、`ACCESS_DDK_USB` 和 `ACCESS_EXTENSIONAL_DEVICE_DRIVER`。
2. 查询与兼容绑定使用 `queryDevices` / `bindDeviceDriver`。本地 API26 `PermissionDefinitions.json` 确认 `ACCESS_EXTENSIONAL_DEVICE_DRIVER` 为 normal/system_grant、不启用 Profile ACL，因此只需声明。旧绑定接口已废弃但仍提供；为减少权限申请，当前采用该兼容路径。
3. 新 `bindDriverWithDeviceId` 需要 system_basic 的 `ACCESS_DDK_DRIVERS` 及其值型 ACL，本阶段不采用，也不要求用户额外申请。
4. 核对 Profile 的开发者证书与本地私钥匹配，使用本地忽略的签名配置构建。Profile 与叶证书匹配不等于私钥匹配，必须完成实际签名验证。
5. 独立开发工程仍可从 `ddk-driver/` 构建。正式驱动并入主工程后，主 HAP 一并部署，避免跨包 Profile 问题。

Profile、证书链、私钥和含签名信息的 `build-profile.json5` 不进入版本管理。仓库中的 `build-profile.example.json5` 仅作无凭据模板。

完成签名与安装只证明部署条件满足。DDK 初始化、设备绑定、真实传输、断连清理和 Windows USB/IP 互通仍须分别验证。
