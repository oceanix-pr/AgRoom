#!/bin/zsh
# ============================================================
# AgRoom 打包脚本（规范 §10：构建与发布）
# 用法：
#   ./scripts/package.sh           Release 构建 + 生成 DMG
#   ./scripts/package.sh --bump    先递增构建号再打包
#
# 说明：
# - 当前使用工程中的 Apple Development 签名 + Hardened Runtime
# - 对外分发需对主 App 和独立执行器使用同团队 Developer ID 签名并公证；
#   不要使用 --deep 重签以免覆盖执行器各自的沙箱权限
# ============================================================
set -euo pipefail

cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PROJECT="AgRoom.xcodeproj"
SCHEME="AgRoom"
DERIVED=".build/release"
DIST=".build/dist"
APP_NAME="AgRoom"

# 可选：递增构建号
if [[ "${1:-}" == "--bump" ]]; then
  ./bump_version.sh
fi

echo "==> Building Release..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  build | tail -3

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$APP" ]]; then
  echo "error: build product not found at $APP" >&2
  exit 1
fi

# 暂存应用包以生成 DMG
rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "$APP" "$DIST/$APP_NAME.app"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DIST/$APP_NAME.app/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$DIST/$APP_NAME.app/Contents/Info.plist")
DMG="$APP_NAME-$VERSION-$BUILD.dmg"

echo "==> Creating DMG ($DMG)..."
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$DIST" -ov -format UDZO "$DMG"

echo "==> Done: $(pwd)/$DMG"
echo "    签名状态: $(codesign -dv "$DIST/$APP_NAME.app" 2>&1 | grep Authority | head -1 || echo 'ad-hoc')"
