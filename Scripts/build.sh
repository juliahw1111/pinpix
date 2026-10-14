#!/bin/zsh
# 本機建置（不需要開發者帳號，用臨時簽章）。上架請用 Xcode 開 Pinpix.xcodeproj → Product › Archive。
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ICONSET=Pinpix/Resources/Assets.xcassets/AppIcon.appiconset

if [[ ! -f "$ICONSET/icon_512x512@2x.png" ]]; then
  mkdir -p "$ICONSET"
  echo '{"info":{"version":1,"author":"xcode"}}' > Pinpix/Resources/Assets.xcassets/Contents.json
  swift Scripts/make_icon.swift "$ICONSET"
fi

xcodegen generate --quiet
mkdir -p build
xcodebuild -project Pinpix.xcodeproj -scheme Pinpix -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  build > build/xcodebuild.log 2>&1 || true
grep -E "error:|warning: .*/Pinpix/Pinpix/" build/xcodebuild.log | sort -u || true
grep -q "BUILD SUCCEEDED" build/xcodebuild.log || { echo "BUILD FAILED（完整紀錄：build/xcodebuild.log）"; exit 1; }

APP=build/DerivedData/Build/Products/Release/Pinpix.app
rm -rf build/Pinpix.app && cp -R "$APP" build/Pinpix.app
echo "→ $(pwd)/build/Pinpix.app"

# ./Scripts/build.sh --install：安裝到「應用程式」資料夾並重新開啟
if [[ "${1:-}" == "--install" ]]; then
  pkill -x Pinpix 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Pinpix.app
  cp -R build/Pinpix.app /Applications/Pinpix.app
  open /Applications/Pinpix.app
  echo "→ 已安裝到 /Applications/Pinpix.app"
fi
