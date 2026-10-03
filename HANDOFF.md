# SideLinker 项目交接文档

写给接手的 AI（Kimi K3）。读完这份文档再动代码。仓库：`yx1100/SideLinker`，工作分支 `feature/menubar-app`（已推送，未合并到 main，未开 PR）。

## 1. 项目目标

用户（以下称「用户」）用 13 英寸 iPad Pro（M4，2752×2064）配合 Mac 使用，即将从 MacBook Pro（M1 Pro）换成 Mac mini。SideLinker 是一个菜单栏 App，覆盖三个场景：

| 场景 | 条件 | 行为 |
|---|---|---|
| 桌面随航 | Mac 接着 1–2 台显示器 | 不做任何事，用户用控制中心自己开随航 |
| 便携随航 | 开机时没有物理显示器（带 Mac mini 出门） | 自动连接 iPad 随航，iPad 是唯一屏幕 |
| UU 远程 | 用户在外面用 iPad 上的网易 UU 远程连入工位的 Mac | 创建 2752×2064 HiDPI 虚拟屏作为唯一屏幕，关闭所有物理显示器，iPad 画面铺满；UU 断开 30 秒后恢复物理屏并锁屏 |

UU 远程的单屏切换：记住的设备（按 UU 设备 ID）连入时自动切换，其他设备连入时只能在设置窗口手动切换。用户明确不要「任何设备连入都自动切换」。

最初 fork 自 `wberry9813/SideLinker`（上游 `Ocasio-J/SidecarLauncher`），原项目只是一个命令行工具，没有界面。

## 2. 当前状态

### 已完成并实测

- 原命令行工具的 4 个 bug（提交 `3b53c90`，之后整个 `SidecarLauncher/` 已删除）
- 随航连接与断开（`SideLinker connect` / `disconnect`），无线 3 秒连上
- 虚拟屏：1376×1032 点、2752×2064 像素的 HiDPI 模式
- UU 远程单屏：用 iPad 实测三轮。切换约 12 秒，恢复约 3 秒后锁屏，分辨率、排列、主屏都能还原
- 锁屏时的延后处理、崩溃后恢复、分辨率记忆
- 菜单栏只读信息 + 设置窗口（SwiftUI，自绘侧栏：随航 / UU 远程 / 通用）
- `selftest` 全部通过

### 已实现但未实测

- **便携随航整条链路**：用户还没有 Mac mini。占位虚拟屏、自动重连、镜像这些逻辑只在代码层面写好，没有在无屏开机的机器上跑过
- **UU 设备记忆后的自动切换**：解析已用真实日志验证，但「勾选后断开再连入自动切换」没有端到端测过
- **最近两次界面改动**（设备显示「系统 · 设备 ID」、「忘记」按钮垂直居中）：编译通过，没有截图确认
- **登录时启动**（`SMAppService.agent`）：没有在 `/Applications` 安装版上注册测试过

### 待办

1. 已完成：App 图标源图是 `artwork/AppIcon.png`（1024×1024，主体 824×824，透明背景），生成的 `Resources/AppIcon.icns` 由 `build.sh` 复制进 App，`Info.plist` 的 `CFBundleIconFile` 为 `AppIcon`。换图标时用新的 PNG 重新生成 iconset，再用 `iconutil -c icns` 生成
2. Mac mini 到手后测便携随航：有线连接、开着 Wi-Fi 但不连任何网络时的无线连接、占位屏是否必要（`noDummy` 开关可以做对照测试）
3. 用户确认没问题后执行 `./build.sh install`，再测登录启动
4. 是否合并到 main、是否开 PR，由用户决定

## 3. 代码结构

```
Package.swift                         Swift 5 语言模式（tools 5.9），macOS 14+
Sources/CGPrivate/include/CGPrivate.h CGVirtualDisplay* 私有类声明 + CGSConfigureDisplayEnabled
Sources/SideLinker/
  main.swift       命令行入口：devices / connect [名称] / disconnect [名称] / selftest；无参数时启动 App
  Sidecar.swift    SidecarCore 私有框架封装（dlopen + NSClassFromString）
  Displays.swift   VirtualScreen、Session（锁屏检测、锁屏）、Displays（单屏进入/恢复、镜像、分辨率）
  UUWatcher.swift  读 UU 日志：会话状态、连入设备；RemoteGate（单屏退出判定）
  App.swift        AppDelegate：状态机、菜单栏、设置窗口、通知、登录启动
  Settings.swift   SettingsModel（ObservableObject）+ SettingsView（SwiftUI）
Resources/Info.plist                  LSUIElement，Bundle ID com.yx1100.sidelinker
Resources/com.yx1100.sidelinker.plist LaunchAgent，KeepAlive{SuccessfulExit=false}
build.sh                              swift build → build/SideLinker.app → ad-hoc 签名；install 参数复制到 /Applications
```

## 4. 关键机制和已踩过的坑

这些都是测试中真实出过问题、改过的地方，改相关代码前务必读。

### 显示配置（Displays.swift）

- **锁屏时 macOS 拒绝一切显示配置**：`CGCompleteDisplayConfiguration` 返回 1014。曾因此让用户三块屏黑了好几分钟。所有切换和恢复都要先看 `Session.isLocked`，锁屏时延后；`restore` 在锁屏中失败时返回 false，必须保留虚拟屏和保存的布局，否则会出现一块显示器都没有的状态
- **每块显示器单独一个配置事务**：一个事务里一块失败，整个事务作废
- **对已经打开的显示器再执行打开，事务会失败**：恢复时只打开当前不在线的
- **打开显示器和取消镜像不能放在同一个事务**：第一次实测恢复失败就是这个原因
- **外接屏重新点亮可能要 10 秒以上**，USB-C 便携屏关闭也要约 10 秒。等待时间不要压得太短
- **恢复顺序**：先打开物理屏并等它们上线 → 取消镜像 → 释放虚拟屏 → 设置分辨率和位置。任何时候都不能出现零显示器
- **UU 连入前约 1 秒会改主屏分辨率**（Kuycon 从 2560×1440 改成 1920×1080），断开时显示器还关着，UU 改不回去。所以 App 平时记录「持续 10 秒没变」的分辨率（`stableModes`），恢复时把分辨率和位置放在同一个事务里设回，3 秒后核对一次。只设位置的话，系统会把 UU 改过的分辨率重新套用回来
- 配置一律用 `.forSession`，注销或重启即还原
- 虚拟屏的回调队列是私有队列；所有会轮询等待的显示操作都在 `work` 串行队列上执行，不要在主线程等待

### UU 远程（UUWatcher.swift、App.swift）

- 日志目录：`~/Library/Application Support/com.netease.uuremote/Logs/UURemoteMac_*.log`，按天换新文件，按文件名排序就是按时间排序
- 会话状态：`"onPeerConnectionState"` 行里 `state` 为 5 表示连上，0 表示断开
- 连入设备：`device_info_changed` 推送里的 `participants_info`，含 `alias`、`device_id`、`platform`。平台编号是推断的：1 Windows，3 iOS/iPadOS，4 macOS（解析时排除 4）。**UU 不提供设备型号**
- 设备名称只出现在设备连入时写的日志里。App 启动时扫全部日志建立 `known` 表，记住的设备名称以最新一条为准
- `RemoteGate`：只能手动进入或由记住的设备触发；断开满 30 秒才退出（日志里见过断开 22 秒后又连上）；没有会话时进入，30 秒后自动退出
- **要求用户关闭 UU 的「结束远程自动锁屏」**：否则 UU 先锁屏，物理屏要等解锁后才能恢复。现在由 SideLinker 恢复后调用 `SACLockScreenImmediate`（login.framework）锁屏。手动点「恢复物理显示器」不锁屏
- 全部依赖 UU 4.38 的日志格式，UU 升级后要先检查这些字段还在不在

### 随航（Sidecar.swift、App.swift）

- 有线连接靠 `SidecarDisplayConfig.setTransport:` 传 2（无文档的约定）
- 回调必须是 `@convention(block)`，用 `unsafeBitCast(block, to: AnyObject.self)` 传入，否则框架回调时崩溃（原项目 disconnect 的 bug）
- 连接超时 20 秒，超时后以 `connectedDevices` 为准，并等旧请求返回，避免叠加
- 设备列表里会出现 Vision Pro，用 `isRealityDevice` 排除
- 便携场景判定：除自己的虚拟屏外没有显示器，且不在单屏模式（单屏模式关掉的物理屏不能算「没有显示器」，曾因此误触发）
- 用户的随航场景说明：Apple 要求 iPad 不能开个人热点；户外推荐 USB-C 线；Mac mini 开 FileVault 就不能自动登录，无屏开机进不了系统，这个取舍由用户决定

## 5. 构建、测试与安全措施

```bash
./build.sh                                    # 构建 build/SideLinker.app
.build/release/SideLinker selftest            # 自检：日志解析、RemoteGate、日志轮转
.build/release/SideLinker devices             # 列出随航设备（只读）
open build/SideLinker.app                     # 运行；再次 open 会弹出设置窗口
```

- 编辑器里的 SourceKit 报错（找不到 `CGPrivate` 模块、找不到其他文件里的类型）是误报，以 `swift build` 的结果为准
- 截图设置窗口：用 `CGWindowListCopyWindowInfo` 找到 SideLinker 的窗口 ID，再 `screencapture -x -o -l <ID>`。computer-use 找不到这个 App（不在应用索引里）
- **任何会关掉屏幕的测试，必须先征得用户同意**，并在后台挂一个安全网：未锁屏、没有 SideLinker 虚拟屏（vendor 0x5344）、物理屏缺失超过 25 秒时，逐块调用 `CGSConfigureDisplayEnabled(true)` 打开。锁屏状态下只能等用户解锁（触控 ID 或盲输密码）后再打开
- 用户这台 MacBook 的显示器：Kuycon P27U（ID 3，5K，looks like 2560×1440，主屏，原点 0,0）、内建屏（ID 1，1800×1169，原点 -2646,522）、CFORCE 竖屏便携屏（ID 2，846×1504，原点 -846,0）

## 6. 用户偏好和协作约定

- 回复用中文；回复第一句先说「信哥」（用户的全局要求）
- **署名**：提交信息、文件、文档里不能出现任何 AI 署名或「由 AI 生成」字样。commit trailer 只写 `Authored-By: Xin <yuxin1100@foxmail.com>`，不写 Co-Authored-By
- 每完成一项改动：`git add` 本次相关文件（不用 `-A`）→ commit → push。force-push、改写历史、开 PR、合并需要单独确认
- 界面文字要精简：用户明确要求删掉所有说明性的副标题和操作提示，只保留状态信息
- 菜单栏只呈现信息，可点的只有「设置…」和「退出 SideLinker」；所有功能放进设置窗口，后续新功能也加在设置窗口侧栏
- 菜单栏图标用 17pt、中等粗细的 SF Symbol 绘制，和其他菜单栏图标大小一致
- 用户偏好原生实现，可以用私有接口，不依赖 BetterDisplay
- 写文档类内容后，用户要求按 `lieflat-less-ai-tone` 规则去掉 AI 腔
