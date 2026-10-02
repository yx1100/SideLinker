# SideLinker

[English](./README.md) | **简体中文**

一个菜单栏小工具，让 iPad 在三种场景下当 Mac 的屏幕：

| 场景 | 判定条件 | SideLinker 做什么 |
|---|---|---|
| 桌面随航 | Mac 接着显示器 | 不做任何事，照常使用系统自带的随航 |
| 便携随航 | 没有任何显示器（例如带 Mac mini 出门） | 开机后自动连上 iPad，iPad 是唯一屏幕 |
| UU 远程 | 用 iPad 上的网易 UU 远程连入 | 只保留一块与 iPad 同尺寸的虚拟屏，关闭物理显示器；断开 60 秒后恢复 |

三种场景自动识别，不用手动切换。全部使用 macOS 自带的接口和私有框架（SidecarCore、CGVirtualDisplay、CGSConfigureDisplayEnabled），不依赖 BetterDisplay。

## 安装

需要 macOS 14 及以上，以及 Xcode 或 Command Line Tools。

```bash
./build.sh install
```

构建结果复制到 `/Applications/SideLinker.app`。首次运行时允许通知；在菜单里勾选「登录时启动」，再按提示到「系统设置 → 通用 → 登录项与扩展」里允许它在后台运行。

## 菜单

- **状态**：随航已连接 / 远程单屏中 / 正在连接随航 / 空闲
- **自动处理**：关闭后不再自动连接随航，也不再自动切换单屏，下面的手动操作仍可使用
- **连接随航 ▸ 设备**：手动连接，先试有线再试无线
- **断开随航**：便携场景下点这里断开，会暂停自动重连
- **进入 / 退出远程单屏**
- **登录时启动**
- **退出**：退出前会恢复被关闭的显示器

## 便携随航

**流程**

1. 随航未连接，且除 SideLinker 自己的虚拟屏外没有任何显示器时触发。
2. 先放一块 1920×1080 的占位虚拟屏（原项目作者发现完全没有屏幕时随航不稳定），再开始连接：上次连上的设备优先，每台先有线后无线。前 2 分钟每 5 秒重试一次，之后每 30 秒一次。
3. 连上后，占位屏改为 iPad 的镜像，iPad 成为唯一屏幕。
4. 随航断开后 10 秒自动重连。在 iPad 上直接断开也会被重连，要真正断开请用菜单里的「断开随航」。
5. 接上物理显示器后自动退出这个场景，随航连接保持不变。

**前提**

- Mac 和 iPad 登录同一个 Apple 账户，并开启双重认证。
- **无线**：两边都打开 Wi-Fi、蓝牙和接力，距离 10 米以内。随航走点对点连接，不需要路由器，也不需要联网。**不要打开 iPad 的个人热点**，Mac 也不要共享网络，否则无线随航连不上（Apple 官方要求）。
- **有线**：用 USB-C 线直连，iPad 需要信任这台 Mac。户外没有 Wi-Fi 网络时这是最稳的方式，还能给 iPad 充电。
- **FileVault**：开着 FileVault 时 macOS 不允许自动登录，没接屏幕的 Mac mini 开机会停在解锁界面，进不了系统，也就连不了随航。两个办法：关闭 FileVault，并在「系统设置 → 用户与群组」里开启自动登录；或者接一个键盘，开机后盲输密码。前者在设备丢失时有数据泄露风险，请自行取舍。

## UU 远程

**流程**

1. 读取 UU 日志（`~/Library/Application Support/com.netease.uuremote/Logs/`）中的 `onPeerConnectionState`，`state` 为 5 表示已连接，0 表示已断开，每 2 秒检查一次。
2. 连入后：创建一块 HiDPI 虚拟屏（1376×1032 点，2752×2064 像素，与 13 英寸 iPad Pro 一致），设为主屏，再逐块关闭物理显示器，所有窗口会集中到这块屏上。个别显示器关不掉时改为镜像这块虚拟屏，这些显示器仍会显示画面。
3. UU 断开满 60 秒后，打开物理显示器，恢复原来的分辨率、排列和主屏，再移除虚拟屏，最后锁屏。60 秒的缓冲用来避免掉线重连时来回切换。

**UU 设置**

- 关闭 UU 的「结束远程自动锁屏」，锁屏交给 SideLinker。锁屏状态下 macOS 不允许修改显示器配置：如果 UU 在断开时先锁了屏，物理屏要等解锁后才能恢复，回到工位会看到全黑的屏幕，需要盲输密码或用触控 ID 解锁，解锁后几秒内恢复。
- UU 连入时会修改物理屏的分辨率，断开时因为显示器还关着，它改不回去。SideLinker 会记住连接前持续 10 秒没变的分辨率，恢复时一起设回去。

**安全措施**

- 锁屏时暂停切换，解锁后自动补做。从外面连入时如果 Mac 处于锁屏，先在 UU 里解锁，随后切到单屏。
- 会话中点「退出远程单屏」后，本次会话不再自动进入，退出后也不锁屏。
- 没有检测到 UU 会话时手动进入，60 秒后自动退出，物理屏不会一直关着。
- App 崩溃后由 launchd 重新拉起，按当时的 UU 状态恢复显示器或重新进入单屏。
- 所有显示配置只在本次登录有效，注销或重启后也会还原。

在 MacBook Pro（M1 Pro，macOS 27.0.1，外接两台显示器）上用 iPad 实测：UU 连上后约 12 秒切换完成（USB-C 便携屏关闭较慢，约 10 秒）；断开 60 秒后开始恢复，约 5 秒后分辨率、排列和主屏都与原来一致，随即锁屏。

## 命令行

排查问题时可以直接调用 App 里的可执行文件：

```bash
/Applications/SideLinker.app/Contents/MacOS/SideLinker devices
```

另外还有 `connect [设备名]`、`disconnect [设备名]` 和 `selftest`（检查日志解析和单屏判定逻辑）。

隐藏设置：

```bash
# 在接着显示器的 Mac 上模拟便携随航流程
defaults write com.yx1100.sidelinker debugForcePortable -bool YES
# 便携随航时不放占位屏
defaults write com.yx1100.sidelinker noDummy -bool YES
```

## 已知限制

- 自动识别依赖 UU 的日志格式，在 UU 4.38 上验证。UU 升级后如果失效，先看日志里是否还有 `onPeerConnectionState`，期间可以用菜单手动进入。
- 不区分从哪台设备连入，用电脑通过 UU 连进来也会切成 4:3 单屏。用这台 Mac 去控制别的设备时是否会误触发，尚未验证。
- iPad 尺寸写在 `Sources/SideLinker/App.swift` 的 `enterRemote()` 里，换 iPad 时需要修改。
- 依赖私有接口，macOS 升级后可能失效。目前在 macOS 27.0.1 上验证。
- 和 BetterDisplay 同时运行时，请关闭 BetterDisplay 的自动连接、配置保护等功能，避免两边互相修改显示配置。
- 便携随航的占位屏是否必要，还需要在无屏的 Mac mini 上实测；不需要的话可用 `noDummy` 关掉。

## 致谢

随航连接方式来自 [Ocasio-J/SidecarLauncher](https://github.com/Ocasio-J/SidecarLauncher) 和 [wberry9813/SideLinker](https://github.com/wberry9813/SideLinker)；虚拟屏接口的声明参照了 [Stengo/DeskPad](https://github.com/Stengo/DeskPad)。
