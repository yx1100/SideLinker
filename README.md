# SideLinker

**English** | [简体中文](./README.zh-CN.md)

A menu bar app that uses an iPad as the Mac's screen in three situations. The Sidecar situations are detected automatically. UU Remote switches automatically only for devices you mark in the settings window (identified by the device ID in UU's logs); for any other device you trigger it from the settings window (menu bar → 设置…):

| Situation | Detected when | What SideLinker does |
|---|---|---|
| Desk Sidecar | The Mac has displays attached | Nothing; use the built-in Sidecar as usual |
| Portable Sidecar | No display is attached (e.g. a Mac mini on the road) | Connects Sidecar to the iPad at login, making it the only screen |
| UU Remote | You choose "切换到 iPad 单屏" in the settings window after connecting with NetEase UU Remote from the iPad | Creates a virtual display matching the iPad (2752×2064 for a 13-inch iPad Pro), turns the physical displays off, and restores them 30 seconds after the session ends |

It uses macOS frameworks and private APIs (SidecarCore, CGVirtualDisplay, CGSConfigureDisplayEnabled) and does not need BetterDisplay.

## Install

Requires macOS 14+ and Xcode or the Command Line Tools.

```bash
./build.sh install
```

Allow notifications on first launch, then enable "登录时启动" (Launch at Login) under General in the settings window and approve it in System Settings → General → Login Items & Extensions.

## Notes

- Wireless Sidecar needs Wi-Fi, Bluetooth and Handoff turned on, but no router or internet. Do not turn on the iPad's Personal Hotspot; Apple's Sidecar requirements say the iPad must not share its cellular connection. A USB-C cable is the most reliable option without Wi-Fi.
- A headless Mac can only start Sidecar after login. With FileVault on, automatic login is unavailable, so either turn FileVault off and enable automatic login, or type the password blind with a keyboard.
- UU session detection (used to restore the displays after you disconnect) reads UU's log files and was verified with UU 4.38.
- Turn off UU's "lock after remote session ends" option. macOS refuses display changes while the screen is locked, so SideLinker restores the displays first and then locks the Mac itself. If UU locks first, the displays stay dark until you unlock (blind password entry or Touch ID).

See the [Chinese README](./README.zh-CN.md) for details, debugging commands and known limitations.
