# USBArc

HarmonyOS PC / 二合一设备上的 USB/IP 图形化共享端。应用使用 usbManager 访问本地 USB 设备，通过 USB/IP 1.1.1 与 Windows 的 usbip-win2 通信。

## 当前开发范围

- 最低 API 26，只适配 `2in1`。
- 手动授权并选择共享设备；可开启接入自动请求授权及自动共享。
- 自动共享支持全部设备或 VID/PID、可选序列号规则。系统授权由用户决定，自动模式不会绕过授权弹窗。
- 提供任务保持、模拟下载模式、系统托盘及关闭到托盘。
- 应用外观支持跟随系统、明亮、黑暗及本地图片背景；主页展示 wlan0 的全部 IPv4/IPv6，设备插拔自动刷新并保留手动刷新。
- 设置提供 USB Manager / USB DDK 选择。独立 `ddk-driver/` 工程的真实 Native DDK 调用已经通过构建，主应用 DDK 客户端与 USB/IP 接入仍在开发；当前选择 DDK 会明确拒绝启动，不回退到 usbManager。

自动共享表示设备进入本机导出列表；远端 Windows 仍需执行 attach。默认不强制抢占系统使用中的 USB 接口；强制选项可能中断本地磁盘、串口或其他程序对该设备的使用。

## 构建与部署

安装 DevEco Studio、API 26 SDK 和官方 DevEco CLI。首次本地构建前：

```powershell
Copy-Item build-profile.example.json5 build-profile.json5
devecocli build --modules entry --build-mode debug
```

实机部署需要独立的调试签名和已连接设备：

```powershell
devecocli auth login
devecocli signature generate --product default
devecocli run --module entry --device <HDC地址>
```

`build-profile.json5` 为忽略文件；签名私钥、证书配置和密码不进入版本库。不要用示例文件覆盖已经配置好的本地签名。

`ddk-driver/` 是独立构建验证工程；正式 DDK 接入正在并入主应用同包，以使用用户已批准的主应用 ACL Profile，详情见 [DDK 签名准备](docs/DDK_SIGNING.md)。

## Windows 连接

在 USBArc 启动服务、授权并共享目标设备后，使用 usbip-win2 客户端：

```powershell
usbip.exe list -r <MateBook地址>
usbip.exe attach -r <MateBook地址> -b <列表中的busid>
```

默认端口为 3240。通配地址 `0.0.0.0` / `::` 请求 IPv4、IPv6 双栈监听，启动时核验实际 socket 地址族、端口及双栈选项；指定具体地址则仅监听该地址。实际连接能力以设备验证记录为准。启动前需要确认监听端口；通过 MeshArc 转发时，还需在 MeshArc 放行对应 TCP 端口，应用内确认不代替该策略。USB/IP 协议自身没有认证或加密，建议通过已有的可信局域网或 Tailscale 使用；USBArc 不内置 Tailscale。

## 能力边界与验证

首版面向 U 盘、J-Link、ST-Link、USB 转 TTL 和 USB CDC，重点处理控制、批量和中断传输；等时传输暂不支持。usbManager 控制传输没有直接取消 API，其取消语义存在限制。

设备速度通过 usbManager 授权后的文件描述符调用只读 `USBDEVFS_GET_SPEED` 查询；接口或系统不支持时协议返回 `USB_SPEED_UNKNOWN`，不根据 `bcdUSB` 猜测。序列号只在用户授权后通过 USB 字符串描述符读取，权限或设备不提供时留空。两者都仍需在目标设备上做互操作验证。

任务保持和模拟下载都是系统后台任务请求。模拟下载不会下载文件或伪造进度，系统可能因没有真实下载活动而取消该任务；PC 建议优先选择任务保持。任何模式都不保证系统永远不结束进程。

MateBook 当前已枚举 U 盘、CH340、CH343、CP2102、CH347T、ST-Link V2/V3。枚举、系统授权、USB/IP 导入及实际数据传输分别验收，不能据构建或协议测试宣称真实 USB 设备兼容性。最新结果见 [验证记录](docs/VALIDATION.md)，界面检查见 [视觉 QA](docs/VISUAL_QA.md)，实施与验收范围见 [开发计划](DEVELOPMENT_PLAN.md)。

界面和桌面生命周期参考同一工作区中的 MeshArc；此项目不包含其 VPN/Tailscale 引擎。

## 参考资料

- [HarmonyOS USBManager API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-usbmanager)
- [HarmonyOS USB DDK 指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/usb-ddk-guidelines)
- [Linux USB/IP 协议](https://docs.kernel.org/usb/usbip_protocol.html)
- [usbip-win2](https://github.com/vadimgrn/usbip-win2)
