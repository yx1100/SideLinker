#!/bin/bash
# 构建 build/SideLinker.app；./build.sh install 额外复制到 /Applications；
# ./build.sh release 额外打包成 build/SideLinker-版本号.zip（仅支持 Apple 芯片）
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/SideLinker"
APP=build/SideLinker.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "已构建 $APP"

if [[ "${1:-}" == release ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  rm -f "build/SideLinker-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "build/SideLinker-$VERSION.zip"
  echo "已打包 build/SideLinker-$VERSION.zip"
fi

if [[ "${1:-}" == install ]]; then
  # 退出旧进程：单屏开启时它要先恢复物理显示器，可能需要几十秒，等它完全退出再启动新版，
  # 否则 open 只会唤起还没退出的旧进程
  if pkill -x SideLinker; then
    for _ in {1..120}; do pgrep -x SideLinker >/dev/null || break; sleep 0.5; done
  fi
  rm -rf /Applications/SideLinker.app
  cp -R "$APP" /Applications/
  echo "已安装到 /Applications/SideLinker.app"
  # 开启了「登录时启动」时交给 launchd 启动，崩溃后会被自动拉起
  JOB="gui/$(id -u)/com.yx1100.sidelinker"
  PLIST="$HOME/Library/LaunchAgents/com.yx1100.sidelinker.plist"
  if [[ -f "$PLIST" ]]; then
    launchctl kickstart "$JOB" 2>/dev/null || launchctl bootstrap "gui/$(id -u)" "$PLIST"
  else
    open /Applications/SideLinker.app
  fi
  echo "已启动"
fi
