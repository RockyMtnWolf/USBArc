# USBArc 开发计划

## 2026-10-17 当前状态

1. 已修复启动后 IPv4 标签读取旧地址快照的问题，删除 wlan0 标题下提示；生产 helper 的启动、停止、指定地址回归用例已通过。
2. 已将 DDK 客户端、DriverExtensionAbility、Native 桥和后端路由并入主包；功能代码 51 项 Local Test 通过，lint 为 0 错误、4 条既有建议。vendor 最新改为 `RockyMtnWolf`，修订包已构建并核对包内信息。
3. `127.0.0.1`、`::1` 的实际 DEVLIST 响应均通过；Windows 直连及 MeshArc IPv4 通过，MeshArc IPv6 路径仍需另查。两族标签及实际默认网卡回退已截图确认。
4. DDK 已通过设备查询、绑定、初始化及描述符读取；名称读取真实 USB 字符串，Hub 已截图确认隐藏。2026-10-16 实机仅扩展坞与 CH340；CH340 在 Windows 正常枚举为 COM3、PnP 问题码为 0，detach 后重新接入成功，未发送串口数据。用户负责远端点击/任务/共享，本机执行 usbip 和截图校验；不操作存储设备。
5. DDK 管道 RPC 已改为单请求单块 Ashmem，最高 1 MiB，不拆分 URB；控制请求上限 1,024 字节。等时、主动取消、强制接管和切换 USB configuration 尚未支持。实际速率只读查询可借用 usbManager，传输始终走 DDK；不能将描述符枚举当成设备兼容性完成。

以下为需求演进记录；旧地址、旧硬件清单与早期 DDK 未接入状态不代表当前快照。

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

后续视觉要求：设备卡片使用从官方开源图标仓库下载的分类图标并保留许可；应用图标重新绘制并具有透明圆角；设置两列有明确间隔；悬浮导航采用 MeshArc 同款 HdsTabs 原生材质与页面切换动画，支持外观调整和持久保存的整页图片背景。

最新网络展示要求：显示本机所有 IPv4 / IPv6 多地址，按协议族和接口组织，长地址完整换行、可复制，保留 IPv6 link-local scope。合并 NetworkKit 和 Native getifaddrs，过滤 unspecified 监听地址，回环地址单独标注。监听配置与本机地址分开；当前 IPv4-only 服务不得把 IPv6 宣称为已支持连接。实机已确认 IPv4 至少包括 `192.168.112.143`（wlan0）与 `172.17.1.1`（ancowlan0）。

用户最新收窄地址展示范围：主页仅显示 `wlan0` 的全部 IPv4/IPv6，其他网卡与回环不展示。默认通过 USB 接入/拔出事件自动刷新设备列表，同时保留手动强制刷新。设置页移除退出按钮；退出入口放在托盘右键菜单及单击弹窗。后台卡片命名为“模拟任务保活”，使用开关控制模式，保持真实后台任务状态及互斥模式约束。

最新扩展：现在开发 DDK 驱动及应用接入，设置支持 usbManager / DDK 显式选择，默认 usbManager，不进行隐式回退。DDK 必须使用 DriverExtensionAbility 生命周期和匹配 ACCESS_DDK_USB ACL 签名；用户确认尚未申请或不确定是否获批，因此本阶段不能声称实机 DDK 已可用。普通应用与受限驱动构建分开，保持默认 HAP 可安装。真实枚举、接口、控制/端点传输和资源释放代码需可构建；未满足权限或驱动绑定条件时显示具体原因。等时传输与运行中取消按公开接口能力明确限制。

应用外观统一为跟随系统 / 黑暗 / 明亮与背景图片，底部导航跟随应用主题；删除原独立导航颜色模式。主题保存并在页面加载后恢复。托盘 SVG 使用标准六位 RGB 色值，避免将 ArkUI ARGB 写法解释成透明 SVG。

DDK 签名方案更新：用户已获批主应用包名的 ACCESS_DDK_USB，Profile 和证书链已提供并忽略。依据官方支持，同一 entry 同时放 UIAbility 与 DriverExtensionAbility，正式部署保持 `io.github.rockymtnwolf.usbarc`，复用该 Profile；独立 DDK 工程仅作开发验证。客户端使用仍可用的旧 bindDeviceDriver，所需 ACCESS_EXTENSIONAL_DEVICE_DRIVER 经本地 SDK 核实为 normal/system_grant，不需要额外 ACL。暂不使用需要值型 ACL 的新 ACCESS_DDK_DRIVERS 绑定接口。此方案替代上述正式跨包部署方案，仍需验证真实签名、初始化、绑定和传输。

最新交互与生命周期修正：设置保存不允许使整页控件统一禁用变灰，按字段排队、保留最新用户意图，慢操作使用局部等待提示。移除设置/首页成功提示和外观、保活卡冗余说明，保活模式只保留任务保持推荐与设备范围说明。设备卡等高、固定行列间距，停止共享后卡片与统计同步。停止服务默认释放实际接口占用，可选择保留；下次启动仅重新占用用户已选择共享的设备。设备授权、实际占用、对外共享和远端使用分别记录，退出应用始终释放资源。

网络新增双栈监听：通配绑定优先 IPv6，并核验实际端口和 IPV6_V6ONLY，必要时追加同端口 IPv4；不接受系统 bind 失败后悄然随机端口。启动前向用户确认监听端口。MeshArc 的入站放行是其自身 Tailnet TCP 转发策略，不是鸿蒙通用防火墙授权；USBArc 不修改 MeshArc，不能声称替它完成端口放行。用户已报告在 MeshArc 允许全部 TCP 后 Windows 能枚举 USBArc 导出设备，该报告不等于代理已验证实际 USB 传输或 IPv6 互通。

## 资料

- https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-usbmanager
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/usb-ddk-guidelines
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/driverdevelopment-overview
- https://github.com/vadimgrn/usbip-win2
- https://github.com/torvalds/linux/blob/master/drivers/usb/usbip/usbip_common.h

## 交付纪律

2026-10-16 继续验证：HDC 使用 `100.116.69.50:37727`，已重新连接。用户当前只接入一个 U 盘和一个硬盘；本轮预览包检查设置交互、布局、实际设备枚举和空共享服务的网络监听，不对存储设备执行远端 attach、读写或强制占用。原有调试器与串口设备的共享/停止/保留占用测试需要之后重新接入对应设备。

各代理不修改他人负责文件，不使用假状态伪装 USB/后台成功。签名文件、密码、构建缓存和设备私有数据不进 Git。每阶段更新验证记录，主代理选择性提交。
