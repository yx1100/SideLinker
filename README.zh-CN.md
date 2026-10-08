# SideLinker

[English](./README.md) | **简体中文**

macOS 菜单栏工具，让 iPad 在三种场景下作为 Mac 的显示器。

| 场景 | 条件 | 行为 |
|---|---|---|
| 桌面随航 | Mac 已连接显示器 | 不做处理，照常使用系统随航 |
| 便携随航 | Mac 未连接任何显示器 | 登录后自动连接 iPad，iPad 作为唯一显示器 |
| 远程连接 | iPad 通过网易 UU 远程接入 | 开启「使用 iPad 单屏显示」后停用物理显示器，只保留一块与 iPad 尺寸相同的虚拟显示器；UU 断开 30 秒后恢复显示器并锁屏 |

基于 macOS 私有框架（SidecarCore、CGVirtualDisplay）实现，不依赖第三方软件。

## 安装

需要 macOS 14 及以上，以及 Xcode 或 Command Line Tools。

```bash
./build.sh install
```

App 安装到 `/Applications/SideLinker.app` 并自动启动。在设置窗口「通用」中开启「登录时启动」，之后由系统负责启动，App 崩溃时会被自动拉起并恢复显示器。

## 使用

**菜单栏**

- 顶部显示当前已建立的连接
- 「随航」一组在已连接时列出 iPad
- 远程连接建立后，可用滑动开关开启或关闭「使用 iPad 单屏显示」
- 「设置…」打开设置窗口

**设置窗口**

- 随航：附近的 iPad 及连接状态，「无显示器时自动连接」开关，无线随航条件和无显示器开机准备的说明
- 远程连接：UU 连接状态；先选择虚拟显示器的屏幕尺寸，再开启「使用 iPad 单屏显示」。UU 的会话日志找不到时，状态显示「无法检测」
- 通用：登录时启动

## 使用前准备

- 随航要求 Mac 和 iPad 登录同一 Apple 账户。无线连接需开启 Wi-Fi、蓝牙和接力，不需要联网，iPad 不能开启个人热点；有线连接使用 USB-C 线
- 便携随航要求 Mac 开机后自动登录，开启 FileVault 时无法自动登录
- 远程连接前关闭 UU 的「结束远程自动锁屏」，锁屏由 SideLinker 在恢复显示器后执行

## 紧急恢复与日志

- 单屏开启时，在 Mac 前按 ⌃⌥⌘R 立即恢复物理显示器，不需要看屏幕
- 运行日志在 `~/Library/Logs/SideLinker.log`，记录 UU 连接和断开、单屏开启和恢复、锁屏、显示配置失败，可用「控制台」App 查看

## 命令行

```bash
/Applications/SideLinker.app/Contents/MacOS/SideLinker devices
```

另有 `connect [设备名]`、`disconnect [设备名]` 和 `selftest`。

## 致谢

随航连接方式来自 [Ocasio-J/SidecarLauncher](https://github.com/Ocasio-J/SidecarLauncher) 和 [wberry9813/SideLinker](https://github.com/wberry9813/SideLinker)；虚拟显示器接口的声明参照了 [Stengo/DeskPad](https://github.com/Stengo/DeskPad)。
