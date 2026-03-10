#!/bin/bash
set -euo pipefail

# XCodeMCPService App Bundle 构建脚本
# 将 SPM 编译产物打包为 macOS .app bundle

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
OUTPUT_DIR="$PROJECT_DIR/build"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"

APP_NAME="XCode MCP Service"
APP_BUNDLE="$OUTPUT_DIR/${APP_NAME}.app"
APP_DMG="$OUTPUT_DIR/XCodeMCPService.dmg"
APP_DMG_CHECKSUM="${APP_DMG}.sha256"
APP_ARCHIVE="$OUTPUT_DIR/XCodeMCPService.app.zip"
APP_ARCHIVE_CHECKSUM="${APP_ARCHIVE}.sha256"
DMG_STAGING_DIR="$OUTPUT_DIR/dmg-root"
EXECUTABLE="XCodeMCPStatusBar"
CLI_EXECUTABLE="XCodeMCPService"

echo "=== Building XCodeMCPService ==="

# 1. Release 编译并解析真实产物目录
swift build -c "$BUILD_CONFIGURATION"
BUILD_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
echo "Build directory: $BUILD_DIR"

# 2. 创建 .app bundle 结构
echo "=== Creating ${APP_NAME}.app ==="
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 3. 复制可执行文件
cp "$BUILD_DIR/$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
cp "$BUILD_DIR/$CLI_EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$CLI_EXECUTABLE"

# 4. 复制 Info.plist
cp "$PROJECT_DIR/Sources/XCodeMCPStatusBar/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# 5. 复制图标
cp "$PROJECT_DIR/Sources/XCodeMCPStatusBar/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# 6. 复制 SPM 资源 bundle（本地化字符串等）
RESOURCE_BUNDLE="$BUILD_DIR/XCodeMCPService_XCodeMCPStatusBar.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "Error: Resource bundle not found at $RESOURCE_BUNDLE" >&2
    exit 1
fi
cp -r "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
echo "Copied resource bundle for localization"

# 7. 创建 PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# 8. 打包 zip 并生成校验文件
rm -f "$APP_DMG" "$APP_DMG_CHECKSUM" "$APP_ARCHIVE" "$APP_ARCHIVE_CHECKSUM"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$APP_ARCHIVE"
shasum -a 256 "$APP_ARCHIVE" > "$APP_ARCHIVE_CHECKSUM"

# 9. 打包 dmg 并生成校验文件
rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
ditto "$APP_BUNDLE" "$DMG_STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING_DIR" \
    -ov \
    -format UDZO \
    "$APP_DMG"
rm -rf "$DMG_STAGING_DIR"
shasum -a 256 "$APP_DMG" > "$APP_DMG_CHECKSUM"

echo ""
echo "=== Build Complete ==="
echo "App:  $APP_BUNDLE"
echo "CLI:  $APP_BUNDLE/Contents/MacOS/$CLI_EXECUTABLE"
echo "DMG:  $APP_DMG"
echo "SHA:  $APP_DMG_CHECKSUM"
echo "ZIP:  $APP_ARCHIVE"
echo "SHA:  $APP_ARCHIVE_CHECKSUM"
echo ""
echo "安装: cp -r \"$APP_BUNDLE\" /Applications/"
echo "运行: open \"/Applications/${APP_NAME}.app\""
