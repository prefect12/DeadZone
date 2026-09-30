#!/bin/zsh
# 编译并打包 DeadZone.app（Universal：Apple 芯片 + Intel）
#   ./build.sh            只构建到 build/DeadZone.app
#   ./build.sh --install  构建并安装到 ~/Applications，然后启动
set -e
cd "$(dirname "$0")"

VERSION="${VERSION:-1.3.1}"
APP=build/DeadZone.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" main.swift AchievementUI.swift Medal3D.swift -o "build/DeadZone-$arch"
done
lipo -create build/DeadZone-arm64 build/DeadZone-x86_64 -output "$APP/Contents/MacOS/DeadZone"
rm build/DeadZone-arm64 build/DeadZone-x86_64

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/ShareCardBackdrop.png "$APP/Contents/Resources/ShareCardBackdrop.png"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.deadzone</string>
  <key>CFBundleName</key><string>DeadZone</string>
  <key>CFBundleDisplayName</key><string>DeadZone</string>
  <key>CFBundleExecutable</key><string>DeadZone</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
EOF

# ad-hoc 签名；把指定要求固定为 bundle id，重新编译后辅助功能授权依然有效
codesign --force -s - -r='designated => identifier "local.deadzone"' "$APP"
echo "构建完成：$APP"

if [[ "$1" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x DeadZone 2>/dev/null || true
  rm -rf ~/Applications/DeadZone.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/DeadZone.app
  echo "已安装并启动：~/Applications/DeadZone.app"
fi
