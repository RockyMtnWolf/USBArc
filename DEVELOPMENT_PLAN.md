# USBArc 开发计划

## 已确认范围

- HarmonyOS PC/2in1，最低、目标和编译 API 26。
- 名称 USBArc，Bundle ID `io.github.rockymtnwolf.usbarc`。
- 首版 USB/IP Server：共享鸿蒙本地 USB 给 Windows 11 usbip-win2。
- 首批验证 U 盘、J-Link、ST-Link、USB 转 TTL、USB CDC。
- usbManager 先行；DDK 后续独立评估，不以占位功能宣称已实现。
- 手动授权/选择共享；用户可开启接入自动授权请求和自动共享。系统授权不能绕过，拒绝时不共享。
- 自动共享范围由用户选择全部设备或指定规则；规则支持 VID/PID 与可选真实序列号，支持添加/删除和持久化，手动共享不受规则限制。
- 参考 MeshArc 原生桌面视觉、任务保持/模拟下载选项、系统托盘、关闭到托盘。
- 仅本地 Git 版本管理，无 GitHub 远端发布。

## 实施阶段与分工

1. 主代理：确认环境、需求、研究能力边界、编写计划、初始化版本管理、审查集成。
2. Luna 后端代理：官方 CLI 创建 Stage ArkTS 工程；USB 设备授权、描述符、接口与传输适配；USB/IP 1.1.1 TCP 流协议，DEVLIST/IMPORT/SUBMIT/UNLINK；设备独占、端点请求调度、长度校验、错误映射和资源清理。
3. Luna 界面代理：共享列表、服务器状态、客户端会话、设置与诊断；手动/自动策略持久化；后台任务与托盘生命周期；窄窗口、深浅色和系统标题栏。
4. Luna 验证代理：独立协议用例、CLI lint/build、签名部署、MateBook UI/日志与 USB 探测；Windows 互操作在对端工具及物理设备具备时完成。

## 架构边界

- `entry` 模块，Ability 管理窗口与生命周期。
- 协议编解码独立于 UI 与 USB API，可使用假后端进行有明确意义的协议测试。
- USB 后端公开设备列表、授权、打开/关闭、控制/端点传输和取消能力。
- Server 按 TCP 流解析，处理拆包/粘包，限制报文长度、客户端数与在途请求；同一设备只允许一个导入会话。
- 控制传输取消没有直接公开 API，必须按实测结果保守处理，记录限制；不得伪造传输成功。
- 异步端点取消的同端点精确性待实测；先采用端点队列，取消尚未提交的请求独立完成。
- 初期不支持等时传输，返回可识别错误；不宣称摄像头/音频支持。
- 默认手动设备共享、不自动强制抢占；自动模式由用户主动启用，系统占用接口时显示失败原因，并提供显式强制选项。
- 默认端口 3240，监听地址可选；USB/IP 本身不提供认证或加密，界面显示实际地址/可达范围，使用现有局域网/Tailscale，避免假称内置网络隔离。
- 自动共享不等于自动连接 Windows；远端仍由 usbip-win2 发起 attach。
- DDK 是驱动扩展/权限受限路线，独立于普通 HAP；USB serial API 仅串口用途，不等同完整 USB/IP 设备后端。

## 验收与证据

| 层级 | 必要检查 | 完成条件 |
|---|---|---|
| 协议 | 网络字节序、拆包/粘包、边界长度、描述符、请求/取消竞争、会话断连 | 独立协议测试通过；真实生产逻辑被调用 |
| 工程 | 官方 CLI lint 与 build | 记录真实 BUILD SUCCESSFUL 与产物，编译不能替代实机 |
| MateBook | 授权拒绝/同意、设备列表、手动/自动共享、设置保存、热插拔 | UI/日志/设备行为有证据；无设备时明确未测 |
| 后台 | taskKeeping、模拟下载、关闭到托盘、打开与退出、系统取消 | 系统任务实际启动、托盘实际注册；限时观测不等同永久保活 |
| Windows | DEVLIST、attach、枚举、实际读写/调试/串口、detach | 对端应用实际使用；没有对端/外设证据时保持未验证 |

## 当前环境基线

DevEco Studio 26.0.0.851，SDK API26 26.0.0.105 Release，CLI 1.3.4，OHPM 26.0.0.630。HDC `100.116.69.50:37727` 已连接，设备 `HUAWEI MateBook Pro S`、API26、2in1。不复制 MeshArc 签名凭据，不修改其现有代码。

初期用户没有物理 USB 外设，先完成无外设测试；后续已准备 WCH-Link、NanoDAP-WL-Host、NanoDLA、CH343、TI EV2400、USB ISP、CH347T-EVT、CANable 2.0、Air DAPLink、CP2102、CH340、AGM DAP-Link、MPS EVKT-USBI2C、ST-Link V2/V3、J-Link V9、ESP32-S3 USB CDC/JTAG。

最新 HDC 地址 `192.168.112.143:37727` 已连接。用户报告当前接入 U 盘、CH343、CH340、CP2102、CH347T、ST-Link V2/V3；以实际枚举确认接入位置和设备标识，逐个记录授权、导出、Windows attach/枚举、传输和 detach 证据。U盘不写入已有数据，调试器不烧写。宿主已安装 usbip-win2 驱动，CLI 位于 `C:\Program Files\USBip\usbip.exe`。

用户优先要求修好 UI，再做后端验证：参考 MeshArc 的主页与分组设置，使用 USB 设备卡片、新应用图标和黑白托盘图标；必须进行实际截图视觉 QA，覆盖宽/窄窗口和深/浅色。只有截图通过才能报告 UI 已完成。

## 资料

- https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-usbmanager
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/usb-ddk-guidelines
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/driverdevelopment-overview
- https://github.com/vadimgrn/usbip-win2
- https://github.com/torvalds/linux/blob/master/drivers/usb/usbip/usbip_common.h

## 交付纪律

各代理不修改他人负责文件，不使用假状态伪装 USB/后台成功。签名文件、密码、构建缓存和设备私有数据不进 Git。每阶段更新验证记录，主代理选择性提交。
