#!/bin/bash
# 构建 build/SideLinker.app；./build.sh install 额外复制到 /Applications
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/SideLinker.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp .build/release/SideLinker "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/com.yx1100.sidelinker.plist "$APP/Contents/Library/LaunchAgents/"
codesign --force --sign - "$APP"
echo "已构建 $APP"

if [[ "${1:-}" == install ]]; then
  # 退出旧进程：单屏开启时它要先恢复物理显示器，可能需要几十秒，等它完全退出再启动新版，
  # 否则 open 只会唤起还没退出的旧进程
  if pkill -x SideLinker; then
    for _ in {1..120}; do pgrep -x SideLinker >/dev/null || break; sleep 0.5; done
  fi
  rm -rf /Applications/SideLinker.app
  cp -R "$APP" /Applications/
  echo "已安装到 /Applications/SideLinker.app"
  # 登录项已注册时交给 launchd 启动，崩溃后会被自动拉起
  JOB="gui/$(id -u)/com.yx1100.sidelinker"
  if launchctl print "$JOB" >/dev/null 2>&1; then
    launchctl kickstart "$JOB"
  else
    open /Applications/SideLinker.app
  fi
  echo "已启动"
fi
