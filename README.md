# ProxyCat

[mihomo](https://github.com/MetaCubeX/mihomo) 的原生 iOS 客户端。架构参考 [sing-box-for-apple](https://github.com/SagerNet/sing-box-for-apple)：SwiftUI 宿主 App 通过 `NEPacketTunnelProvider` 扩展承载网络隧道，扩展内嵌一份由 `gomobile` 生成的 mihomo XCFramework。

> [!NOTE]
> **TestFlight 公测即将开放 / TestFlight beta coming very soon** — 公开邀请链接将很快在此 README 发布，敬请关注本仓库。

## 截图

| Dashboard | Profiles | Logs | Settings |
|:---:|:---:|:---:|:---:|
| <img src="assets/IMG_2721.png" width="200"> | <img src="assets/IMG_2722.png" width="200"> | <img src="assets/IMG_2723.png" width="200"> | <img src="assets/IMG_2725.png" width="200"> |
| 状态 / 流量 / 内存预算 / 活动连接 | YAML profile 管理 | 等级筛选 + 搜索 + 复制 | 隐私 / 存储 / Auto Connect / 诊断 |

## 目录结构

```
proxycat/
├── libmihomo/              Go gomobile 包装层。对外暴露一个极简的 C 友好接口：
│   ├── binding.go          生命周期（Start / Reload / Stop）、路径配置、TUN fd 注入、SetLogLevel、Version
│   ├── settings.go         读取宿主写入的 settings.json（运行时偏好的真源）
│   ├── command_server.go   扩展内的 gRPC 服务（Status + Logs 流）
│   ├── command_client.go   宿主侧 gRPC 客户端，回调通过 gomobile 抛回 Swift
│   ├── log_bridge.go       订阅 mihomo log.Subscribe()，转发到 gRPC 流
│   ├── log_persist.go      把每次会话的日志写到 App Group 的滚动文件中
│   ├── traffic.go          上下行 / 总流量 / 连接数快照
│   ├── oom.go              移植自 sing-box 的 OOM 守护，应对 NE jetsam
│   ├── proto/command/      gRPC 协议定义（Status / Log）
│   └── tools.go            固定 golang.org/x/mobile/bind 依赖（gobind 需要）
├── scripts/
│   └── build-libmihomo.sh  gomobile bind → Frameworks/Libmihomo.xcframework
├── Library/                共享 Swift framework：
│                           LibmihomoBridge / ExtensionProfile / ExtensionEnvironment /
│                           CommandClient / RuntimeSettings / HostSettingsStore /
│                           AutoConnect / Profile / ProxiesStore / ConnectionsStore /
│                           MemoryMonitor / FilePath（AppGroup 路径辅助）
├── ApplicationLibrary/     SwiftUI 视图：Dashboard / Profiles (含编辑器与下载) /
│                           Logs (含 SavedLogs) / Connections / Proxies /
│                           Settings (含 AutoConnect / Advanced)
├── Pcat/                   iOS App target（入口、Info.plist、entitlements）
├── PcatExtension/          Network Extension target（PacketTunnelProvider）
├── project.yml             XcodeGen 描述文件 — 用于（重新）生成 ProxyCat.xcodeproj
├── Makefile                构建编排
└── sample-profile.yaml     最小可用的 mihomo 配置示例
```

## 环境要求

```bash
brew install xcodegen
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
gomobile init
```

mihomo 源码以 git submodule 形式 vendored 在 `proxycat/mihomo/`，跟踪上游 `Alpha` 分支。`libmihomo/go.mod` 中的 `replace` 指向该子模块。

```bash
git clone --recurse-submodules <proxycat repo>
# 或者已经 clone 过：
make mihomo-init        # 等价于 git submodule update --init --recursive mihomo
```

升级到最新 Alpha tip 并重建 xcframework：

```bash
make mihomo-upgrade     # git submodule update --remote mihomo + ./scripts/build-libmihomo.sh
git add mihomo && git commit -m "Bump mihomo to <sha>"
```

`libmihomo/tools.go` 显式 import 了 `golang.org/x/mobile/bind`。没有这个文件 `gomobile bind` 会报错 `unable to import bind: no Go package in golang.org/x/mobile/bind`，因为 `go mod tidy` 会把没有源码引用的依赖剪掉，而 `gobind` 只在临时目录里 import 它。

## 首次构建

```bash
cd proxycat
make assets       # 下载 GeoIP / GeoSite / mmdb 与 metacubexd（仓库只跟踪 .gitkeep）
make all          # 构建 xcframework + 生成 xcodeproj
open ProxyCat.xcodeproj
```

在 Xcode 中给 `Pcat` 与 `PcatExtension` 两个 target 填入 `DEVELOPMENT_TEAM`，然后 Run。

常用 Make target：

| target            | 说明                                                   |
|-------------------|--------------------------------------------------------|
| `make libmihomo`      | 仅重建 `Frameworks/Libmihomo.xcframework`              |
| `make project`        | 运行 `xcodegen` 并自动注入版本号（见下）               |
| `make version`        | 打印下一次 `make project` 会写入的版本/编号            |
| `make all`            | `mihomo-init` + `libmihomo` + `project`，首次 clone 后跑一次 |
| `make mihomo-init`    | 初始化或刷新 `mihomo/` submodule                       |
| `make mihomo-upgrade` | 拉取最新 Alpha tip 并重建 xcframework                  |
| `make assets`         | 下载 geo 资源与 metacubexd 到 `BundledAssets/`         |
| `make geo-assets` / `ui-assets` / `clean-assets` | 仅刷新 / 清空对应子集 |
| `make sim`            | 不签名地为 iOS 模拟器构建                              |
| `make build`          | 真机构建（需要签名）                                   |
| `make clean`          | 清理生成产物                                           |

## 版本与显示信息

应用元数据集中在 `project.yml` 中，由 `xcodegen` 写入 `ProxyCat.xcodeproj`，再由 Xcode 在编译时合并到 `Info.plist`：

| 项目                  | 来源                                                       | Xcode Target → General 字段 |
|-----------------------|------------------------------------------------------------|------------------------------|
| Marketing version     | `VERSION` 文件（手动 bump）                                | Version                      |
| Build number          | `git rev-list --count HEAD`（自动单调递增）                | Build                        |
| Display Name          | `INFOPLIST_KEY_CFBundleDisplayName`（`project.yml`）       | Display Name                 |
| App Category          | `INFOPLIST_KEY_LSApplicationCategoryType`                  | Category                     |

调用链：`make project` → `scripts/generate-project.sh` 读取 `VERSION` 与 git，导出 `PROXYCAT_MARKETING_VERSION` / `PROXYCAT_BUILD_NUMBER`，由 `project.yml` 的 `${...}` 占位符插入。

要发布新版只需 `echo 1.0.0 > VERSION && make project`；build number 会随 commit 自动递增，无需手动维护。需要临时覆盖时（例如手工 archive 至 TestFlight）可：

```bash
PROXYCAT_BUILD_NUMBER=4242 make project
```

`Pcat/Info.plist` 与 `PcatExtension/Info.plist` 现在只保留 `INFOPLIST_KEY_*` 不能表达的条目（YAML profile 的 UTI、Network Extension 的 `NSExtension` 字典）。其他都从 `project.yml` 的 build settings 流入，避免一处版本三处改。

## 内存预算与 OOM 守护

iOS 会对 `NEPacketTunnelProvider` 强制施加一个**未公开**的内存上限——历史上约 15MB，新版 iOS 上有时会到 50MB；Apple 明确建议[不要硬编码这个数字](https://developer.apple.com/forums/thread/106377)。ProxyCat 不依赖绝对值，而是对压力**信号**作出反应。

OOM 守护实现在 `libmihomo/oom.go`，从 sing-box 的 `service/oomkiller`（Apache-2.0）移植，分三层：

1. **软 GC**：`runtime/debug.SetMemoryLimit(armed)` 让 Go 在 jetsam 介入之前就主动加大回收力度；
2. **自适应轮询**：通过 `phys_footprint` 读取 mach `task_vm_info`，根据当前压力状态切换 100ms / 1s / 10s 三档间隔（纯 Go 实现，不依赖 Swift `DispatchSource`）；
3. **触发响应**：`runtime/debug.FreeOSMemory()` 把 slab 还给内核 + `statistic.DefaultManager.Range(close)` 关闭所有活动连接（连接缓冲是稳态下最大的内存来源）。

宿主 App 通过 `SetMemoryLimit(int64)` 设置预算。该值会随 gRPC `StatusMessage.memory_budget` 推送给 Dashboard，UI 因此能展示 `已用 / 预算` 的实时比值。

mihomo 自身的运行时日志缓冲被刻意保持在很小的规模——真正的日志保留发生在宿主 App 中。

## 宿主 App ↔ 扩展 IPC

完全对应 sing-box `experimental/libbox.CommandServer` 的方案，由两条独立通道组成：

**1. gRPC 流（扩展 → 宿主）** — 高频遥测。

- 扩展端启动一个 gRPC server，监听 App Group 容器内的一个 Unix domain socket（路径来自 `Library/FilePath.swift`）。
- `Command` 服务有两个流：
  - `SubscribeStatus(StatusRequest) returns (stream StatusMessage)`：每秒推送 `up / down / upTotal / downTotal / connections / memoryResident / memoryBudget`；
  - `SubscribeLogs(LogRequest) returns (stream LogMessage)`：转发 `log.Subscribe()` 的事件流。
- 宿主 App 一侧不引入 grpc-swift；gRPC client 也住在 Go 里（`libmihomo/command_client.go`），Swift 只实现一个 `LibmihomoCommandClientHandlerProtocol` 委托，由 gomobile 桥回调。这样 Swift 端的依赖足迹为零。
- `Library/CommandClient.swift` 是 `ObservableObject`，封装重连退避（200ms → 5s 上限），SwiftUI 视图直接 `@EnvironmentObject` 订阅。

**2. Provider message（宿主 → 扩展）** — 低频控制信号，走 NetworkExtension 自带的 `NETunnelProviderSession.sendProviderMessage`，在 `PacketTunnelProvider.handleAppMessage` 落地：

| 消息 | 作用 |
|---|---|
| `ping` | 连通性探测（返回 `pong`） |
| `reload` | 重读 YAML + `settings.json` 并触发完整 `hub.ApplyConfig`（用于切换 profile / 编辑当前 YAML / 切换 `disableExternalController` 等需要重建监听 / 代理 / 规则 / DNS 的变更） |
| `setLogLevel:N` | 直接调用 `log.SetLevel`，对应 mihomo 自身 `/configs` PATCH 处理 log level 的轻量路径，不触发 reload |

宿主端的运行时偏好集中在 `Library/RuntimeSettings.swift`，写入 `settings.json` 后，再由 `Library/ExtensionEnvironment.swift` 把变更转换成 `reload` 或 `setLogLevel` 消息发给扩展。

mihomo 自身的 REST 控制器（`external-controller`）默认绑定到 `127.0.0.1:9090`，搭配 `metacubexd` 作为 `external-ui`；用户可以在 Settings 里关掉它（写入 `settings.json` 的 `disableExternalController`，下一次 reload 生效）。它面向最终用户调试，与本仓库的私有 IPC 是两条独立通道。

## 日志视图

`ApplicationLibrary/LogView.swift` 提供：

1. **等级筛选**：Picker 固定提供 `Debug / Info / Warning / Error / Silent` 五档。选择项持久化到 App Group 内的 `settings.json`（默认 WARNING），由 `Library/RuntimeSettings.swift` 集中管理；切换时宿主向扩展发一条 `setLogLevel:N` provider message，扩展直接调用 `log.SetLevel`，不会触发完整 reload。YAML 中的 `log-level` 字段在运行时被刻意忽略——宿主 App 拥有该设置，避免 import 一份带 `log-level: debug` 的 profile 时被反向覆盖。筛选规则为 `entry.level >= cutoff`（DEBUG=0 → SILENT=4，所以选 `Warning` 会显示 Warning + Error）。
2. **搜索框**：`.searchable` + 250ms 去抖；命中部分在 `LogRow` 内联高亮。
3. **复制全部**：把 `viewModel.visible` 一次性写入 `UIPasteboard.general`（即当前等级 + 搜索过滤后剩下的内容），并以 alert 报告复制行数。

`Pause / Resume` 冻结快照，便于不被自动滚动顶到底部。`Clear` 同时清空内存环形缓冲区。会话级日志另由 `libmihomo/log_persist.go` 写入 App Group 的滚动文件，可在 Logs 标签页右上角进入 `SavedLogsView` 查看。

## 配置文件

ProxyCat 直接消费 mihomo 标准 YAML。Profiles 标签页支持：

- 通过文档选择器导入 `.yaml` / `.yml` 文件；
- 在内置编辑器粘贴 / 编辑 YAML（保存前会调用 `LibmihomoValidate` 做语法校验）；
- 滑动删除。

YAML 中需保留 `tun.enable: true`。但**不要**自己写 `tun.file-descriptor`：fd 由 Network Extension 在运行时通过 `SetTunFd` 注入。同时 `binding.go` 的 `prepareConfig`（在每次 Start / Reload 时执行）会强制覆盖以下 TUN 字段以适配 iOS NE 沙箱：

| 字段                                    | 强制值                  | 原因                                                         |
|-----------------------------------------|------------------------|--------------------------------------------------------------|
| `tun.stack`                             | `gvisor`               | NE 沙箱禁止 `system` 栈所需的内核 socket 调用                |
| `tun.auto-route` / `auto-detect-interface` | `false`            | iOS 由 `NEPacketTunnelNetworkSettings` 接管路由，自检会回环  |
| `tun.inet4-address` / `inet6-address`   | `198.18.0.1/16` / `fd00:7f::1/64` | 必须与 `PacketTunnelProvider` 配置的虚拟地址一致 |
| `general.interface` / `routing-mark`    | 空 / 0                 | iOS NE 已豁免扩展自身 socket，不要重复绑定                   |

`sample-profile.yaml` 是最小可运行的范本。

## 构建标识与诊断

`scripts/build-libmihomo.sh` 通过 `go build -ldflags -X` 注入构建期信息：

- `mihomo` 语义版本（来自 `mihomo/constant/version.go`）
- mihomo 上游 commit 短哈希（来自 `git -C mihomo rev-parse`）
- xcframework 打包时间
- 启用的 build tags

Settings → Diagnostics 页面展示 `Libmihomo.Version()` 返回的 `VersionInfo`，方便附在 issue 报告中。

构建标签当前使用 `with_gvisor with_low_memory`：

- `with_gvisor`：保留 sing-tun 的 gVisor netstack（NE 必需）；
- `with_low_memory`：把 mihomo 每连接中继缓冲减半（TCP 32→16KB，UDP 16→8KB），并打开 `features.WithLowMemory`。100 个并发连接约可省 2.4MB。

构建脚本最后还会对 xcframework 各 slice 执行 `strip -x`，进一步压缩 NE 进程的二进制体积。

## 故障排查

| 现象 | 可能原因 |
|---|---|
| `No such module 'Libmihomo'` | 忘了跑 `make libmihomo` |
| 连上 5 秒就掉线 | 触发 jetsam — 在 Console.app 检查是否有 `PcatExtension` 的 `EXC_RESOURCE` |
| `could not obtain TUN file descriptor` | 跨版本 iOS 的 KVC 路径变了 — 见 `PacketTunnelProvider.packetFlowFileDescriptor()` |
| 连接成功但所有流量直连 / 全黑 | 检查 YAML 的 `external-controller` 是否可达，并查 Logs 标签页 |
| Dashboard 上 `Memory` 一直为 0 | 扩展尚未起来，`CommandClient` 还在重连退避中 |
