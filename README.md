# USBArc

HarmonyOS PC / 二合一设备上的 USB/IP 图形化共享端。应用提供 usbManager 与 USB DDK 两种本地设备后端，通过 USB/IP 1.1.1 与 Windows 的 usbip-win2 通信。

## 当前开发范围

- 最低 API 26，只适配 `2in1`。
- 手动授权并选择共享设备；可开启接入自动请求授权及自动共享。
- 自动共享支持全部设备或 VID/PID、可选序列号规则。系统授权由用户决定，自动模式不会绕过授权弹窗。
- 提供任务保持、模拟下载模式、系统托盘及关闭到托盘。
- 应用外观支持跟随系统、明亮、黑暗及本地图片背景；主页优先展示 wlan0 的全部 IPv4/IPv6，无地址时显示真实默认网卡并标注名称。设备插拔自动刷新并保留手动刷新。
- 设置提供 USB Manager / USB DDK 选择；DDK 驱动扩展与客户端已经并入主应用。选择 DDK 会通过真实驱动绑定、初始化和描述符读取确认设备，不回退到 usbManager。实机传输兼容性仍待验证，当前限制见 [DDK 后端范围](docs/DDK_BACKEND_LIMITATIONS.md)。

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

### 本地 Release-mode 验证

本地检查 Release 配置时运行：

```powershell
devecocli build --modules entry --build-mode release
```

这会使用忽略文件 `build-profile.json5` 中现有的本地签名配置。当前配置引用的 `USB_DDK_TestDebug.p7b` 已由官方工具核验为 **debug 类型** Profile；因此，即使构建模式为 `release`，生成物也只是 **Release-mode、debug-profile 签名的本地测试 HAP**，不是市场或生产签名包，也不表示已达到上架条件。构建成功只证明本地 Release 构建链可用。

构建后可用 DevEco SDK 自带的 `hap-sign-tool.jar verify-app` 验证实际生成的签名 HAP。将命令输出的证书链、嵌入 Profile 和任何摘要文件放在 Git 忽略的 `.cache/validation/` 下；审查时只汇报 Profile 类型、bundle name 和 ACL allowlist，不打印或提交 Profile 内容、私钥或密码。这个验证流程只检查本地构建产物，不执行远端发布。

正式 DDK 接入采用主应用同包方案，需要签名 Profile 获批 `ohos.permission.ACCESS_DDK_USB`；自动生成普通调试 Profile 不能代替该权限。详情见 [DDK 签名准备](docs/DDK_SIGNING.md)。

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

DDK 模式也仅为真实速率查询临时借用 usbManager，并在读取后关闭该句柄；设备占用和数据传输仍使用 DDK。速率读取失败时不共享该设备，因为 usbip-win2 不接受未知速率。DDK 显示设备实际产品字符串，读取失败则使用清楚的 VID/PID，不显示系统硬件路径。

任务保持和模拟下载都是系统后台任务请求。模拟下载不会下载文件或伪造进度，系统可能因没有真实下载活动而取消该任务；PC 建议优先选择任务保持。任何模式都不保证系统永远不结束进程。

2026-10-16 最后验证时实机仅扩展坞与 CH340。DDK 路径已通过 Windows usbip-win2 接入、COM3 正常枚举、detach 及重新接入；未打开串口或发送 UART 数据。扩展坞 Hub 已隐藏。此前 SanDisk 与 RTL9210B-CG 仅验证绑定和描述符读取，不能据此宣称存储兼容。最新结果见 [验证记录](docs/VALIDATION.md)，界面检查见 [视觉 QA](docs/VISUAL_QA.md)，实施与验收范围见 [开发计划](DEVELOPMENT_PLAN.md)。

界面和桌面生命周期参考同一工作区中的 MeshArc；此项目不包含其 VPN/Tailscale 引擎。

## 参考资料

- [HarmonyOS USBManager API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-usbmanager)
- [HarmonyOS USB DDK 指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/usb-ddk-guidelines)
- [Linux USB/IP 协议](https://docs.kernel.org/usb/usbip_protocol.html)
- [usbip-win2](https://github.com/vadimgrn/usbip-win2)
