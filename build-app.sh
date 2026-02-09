#!/bin/bash
set -euo pipefail

# XCodeMCPService App Bundle 构建脚本
# 将 SPM 编译产物打包为 macOS .app bundle

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
BUILD_DIR="$PROJECT_DIR/.build/release"
OUTPUT_DIR="$PROJECT_DIR/build"

APP_NAME="XCode MCP Service"
APP_BUNDLE="$OUTPUT_DIR/${APP_NAME}.app"
EXECUTABLE="XCodeMCPStatusBar"
CLI_EXECUTABLE="XCodeMCPService"

echo "=== Building XCodeMCPService ==="

# 1. Release 编译
swift build -c release

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
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -r "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    echo "Copied resource bundle for localization"
else
    echo "Warning: Resource bundle not found at $RESOURCE_BUNDLE"
fi

# 7. 创建 PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo ""
echo "=== Build Complete ==="
echo "App:  $APP_BUNDLE"
echo "CLI:  $APP_BUNDLE/Contents/MacOS/$CLI_EXECUTABLE"
echo ""
echo "安装: cp -r \"$APP_BUNDLE\" /Applications/"
echo "运行: open \"/Applications/${APP_NAME}.app\""
