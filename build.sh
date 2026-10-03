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
  osascript -e 'quit app id "com.yx1100.sidelinker"' 2>/dev/null || true
  rm -rf /Applications/SideLinker.app
  cp -R "$APP" /Applications/
  echo "已安装到 /Applications/SideLinker.app"
fi
