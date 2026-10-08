# SideLinker

**English** | [简体中文](./README.zh-CN.md)

A macOS menu bar app that uses an iPad as the Mac's display in three situations.

| Situation | Condition | Behavior |
|---|---|---|
| Desk Sidecar | The Mac has a display attached | Does nothing; use the system's Sidecar as usual |
| Portable Sidecar | No display is attached | Connects Sidecar to the iPad after login, making it the only display |
| Remote connection | The iPad connects through NetEase UU Remote | Turning on "使用 iPad 单屏显示" disables the physical displays and keeps one virtual display matching the iPad's size; 30 seconds after UU disconnects, the displays are restored and the Mac is locked |

Built on macOS private frameworks (SidecarCore, CGVirtualDisplay), with no third-party dependencies.

## Install

Requires macOS 14 or later and Xcode or the Command Line Tools.

```bash
./build.sh install
```

The app is installed to `/Applications/SideLinker.app` and started. Turn on "登录时启动" (Launch at Login) under 通用 (General) in the settings window; launchd then starts the app and relaunches it after a crash, which restores the displays.

## Usage

**Menu bar**

- The top section lists the connections currently established
- The Sidecar section lists the connected iPad
- While a remote connection is active, a switch turns "使用 iPad 单屏显示" on or off
- "设置…" opens the settings window

**Settings window**

- Sidecar: nearby iPads and their status, the "connect automatically when no display is attached" switch, and notes on wireless Sidecar and headless startup
- Remote connection: UU status; choose the screen size of the virtual display, then turn on "使用 iPad 单屏显示". The status reads "无法检测" (cannot detect) when UU's session log is missing
- General: Launch at Login

## Before you start

- Sidecar requires the Mac and iPad to use the same Apple Account. Wireless Sidecar needs Wi-Fi, Bluetooth and Handoff turned on but no internet, and the iPad's Personal Hotspot must be off; a USB-C cable works for a wired connection
- Portable Sidecar requires the Mac to log in automatically, which is unavailable while FileVault is on
- Turn off UU's "lock after remote session ends" option; SideLinker locks the Mac after restoring the displays

## Emergency restore and log

- While single-screen mode is on, press ⌃⌥⌘R at the Mac to restore the physical displays without looking at the screen
- The log at `~/Library/Logs/SideLinker.log` records UU connections, single-screen changes, locking and display configuration errors; open it in Console

## Command line

```bash
/Applications/SideLinker.app/Contents/MacOS/SideLinker devices
```

`connect [name]`, `disconnect [name]` and `selftest` are also available.

## Credits

The Sidecar connection method comes from [Ocasio-J/SidecarLauncher](https://github.com/Ocasio-J/SidecarLauncher) and [wberry9813/SideLinker](https://github.com/wberry9813/SideLinker); the virtual display declarations follow [Stengo/DeskPad](https://github.com/Stengo/DeskPad).
