<div align="center">

[English](README.md) | **简体中文**

# USBArc

<img src="AppScope/resources/base/media/app_icon.png" width="96" alt="USBArc 应用图标">

**面向 HarmonyOS 二合一设备的原生 USB/IP 服务端。**

> **DDK 签名要求：**USB DDK 是可选的运行时后端，但当前合并版 HAP 无条件声明 `ohos.permission.ACCESS_DDK_USB` 和 `ohos.permission.ACCESS_EXTENSIONAL_DEVICE_DRIVER`。使用普通 Profile 安装该合并包尚未验证，即使选择 USBManager 模式也一样。选择 USBManager 不会移除 DDK ACL 要求。若没有获批的 DDK ACL，需从源码构建仅 USBManager 版本，并移除 DDK 权限和驱动扩展；该配置尚未测试。

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-API%2026-007DFF?style=for-the-badge)](https://developer.huawei.com/consumer/cn/)
[![设备类型](https://img.shields.io/badge/设备-二合一-3DA5D9?style=for-the-badge)](#兼容性与测试状态)
[![协议](https://img.shields.io/badge/协议-USB%2FIP-0A7EA4?style=for-the-badge)](https://github.com/vadimgrn/usbip-win2)
[![可选 DDK](https://img.shields.io/badge/USB%20DDK-可选-6B7280?style=for-the-badge)](#权限)

[源码仓库](https://github.com/RockyMtnWolf/USBArc) · [English](README.md)

</div>

---

USBArc 通过 USB/IP 1.1.1 共享连接到 HarmonyOS 二合一电脑的 USB 外设。Windows 客户端可使用 [usbip-win2](https://github.com/vadimgrn/usbip-win2) 查看并连接已共享设备。USBArc 是独立项目，不包含 MeshArc、Tailscale 或 VPN 功能。

## 功能

- **两种明确的设备后端：**普通应用路径为 USBManager；USB DDK 是可选后端，需要获批 ACL 的签名 Profile。DDK 不可用时不会静默回退到 USBManager。
- **由用户控制访问：**可手动请求 USB 系统授权，也可启用自动请求。自动模式只向系统申请，不会静默批准设备。自动共享可选择全部设备或已保存的 VID/PID 规则。
- **桌面工作流：**自适应设备卡片、实时服务端和客户端状态、系统托盘与关闭到托盘。
- **网络地址显示：**分别显示检测到的本机 IPv4、IPv6 地址和监听配置；界面按服务端实际绑定的地址族报告监听状态。
- **可选后台任务请求：**任务保持与模拟数据传输任务。模拟模式不会下载文件，也不会伪造进度；系统可能取消任一任务。
- **外观：**跟随系统、明亮或黑暗主题，并可选择本地图片作为背景。

目标外设包括 USB 存储、J-Link、ST-Link、USB 转 TTL 适配器及 CDC 串口设备。实际兼容性取决于设备、接口描述符、后端和主机系统；这些类型不代表所有型号或传输方式都可用。

## 兼容性与测试状态

| 项目 | 支持情况 |
| --- | --- |
| 最低及目标 API | HarmonyOS API 26 |
| 声明的设备类型 | 仅二合一设备 |
| 验证使用的 USB/IP 客户端 | Windows `usbip-win2` |
| USB/IP 协议 | 1.1.1 |
| 等时传输 | 暂不支持 |

近期在 API 26 的 HUAWEI MateBook Pro S 上使用 DDK 后端测试了 CH340 USB 转串口和 ST-Link V2。Windows 对两台设备均报告 PnP `ProblemCode 0`；用户也确认通过 ST-Link 使用 STM32CubeProgrammer 成功读取。首次 ST-Link 连接曾出现超时，原因和复现情况仍在观察中。以上结果仅适用于这两台设备和该测试环境。尚未确认 USB 存储、其他型号、其他 HarmonyOS 设备类型及广泛传输兼容性。

DDK 模式读取 USB 速度时，会在取得 USB 授权后临时打开只读 USBManager pipe，读取后立即关闭；USB 接口占用和数据传输仍由 DDK 完成。如果无法读取速度，设备不会导出，因为已测试的 Windows 客户端不接受未知速度。

## 安装

前往 [GitHub Releases](https://github.com/RockyMtnWolf/USBArc/releases) 获取未签名 HAP 和发布说明。设备通常要求安装包具有系统接受的签名；请使用自己获准使用的凭据签名。不要分享签名密钥或 Provisioning Profile。

USBManager API 本身不需要 DDK ACL。不过，当前合并版 HAP 无条件声明 `ACCESS_DDK_USB` 和驱动扩展，使用普通 Profile 安装尚未验证，即使选择 USBManager 模式也一样。使用可选 DDK 后端时，签名 Profile 必须包含获批的 `ohos.permission.ACCESS_DDK_USB` ACL。没有该 ACL 时，应从源码移除 DDK 权限和驱动扩展后构建仅 USBManager 版本；该配置尚未测试。

## 构建

安装 DevEco Studio、HarmonyOS API 26 SDK 和 DevEco CLI。首次检出且尚无本地工程设置时，从仓库中的示例初始化：

```powershell
Copy-Item build-profile.example.json5 build-profile.json5
```

如果要将构建产物安装到设备，请自行配置本地签名。签名设置应留在本机，不要提交到版本库。然后在仓库根目录构建：

```powershell
devecocli build --modules entry --build-mode debug
```

构建 release `.app` 安装包：

```powershell
devecocli build --product default --build-mode release --assemble-type assembleApp
```

源码仓库不提供签名凭据。未签名的本地构建不一定能安装到设备。测试 DDK 时，应使用获批了 DDK ACL 的 Profile。

## 从 Windows 连接

在 USBArc 中启动服务、授权设备并选择共享，然后使用 USBArc 显示的地址和 bus ID：

```powershell
usbip.exe list -r <USBArc-address>
usbip.exe attach -r <USBArc-address> -b <bus-id>
```

默认端口为 `3240`。USBArc 仅在用户确认端口且系统成功绑定 socket 后开始监听。通过 MeshArc 连接时，也要在 MeshArc 的入站策略中放行该端口；USBArc 无法授予系统防火墙权限或其他应用的入站访问权限。USB/IP 本身不提供身份验证或加密。请使用可信网络或单独保护的隧道，不要将服务暴露在不可信网络中。

## 截图

![USBArc 设备列表](image/01-devices.png)

![USBArc 设置页](image/02-settings.png)

![USBArc 深色主题设备列表](image/03-devices-dark.png)

## 权限

USB 设备授权、可选 DDK 访问、后台任务请求和网络监听是相互独立的控制项。具体要求和限制见 [docs/PERMISSIONS.md](docs/PERMISSIONS.md)。

## 许可证

USBArc 使用 [BSD 3-Clause License](LICENSE)。第三方组件声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 参考资料

- [HarmonyOS USB 服务概览](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V14/usb-overview-V14)
- [外设驱动开发与签名](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V13/driverextensionability-V13)
- [USB DDK 指南（OpenHarmony）](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/device/driver/usb-ddk-guidelines.md)
- [申请调试 Profile 与 ACL 权限](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/agc-help-debug-profile-0000002248181278)
- [usbip-win2](https://github.com/vadimgrn/usbip-win2)
