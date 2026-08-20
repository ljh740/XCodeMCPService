#!/bin/bash
set -euo pipefail

# XCodeMCPService App Bundle 构建脚本
# 将 SPM 编译产物打包为 macOS .app bundle

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
OUTPUT_DIR="$PROJECT_DIR/build"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
CODE_SIGN_RUNTIME="${CODE_SIGN_RUNTIME:-1}"
CODE_SIGN_TIMESTAMP="${CODE_SIGN_TIMESTAMP:-auto}"

APP_NAME="XCode MCP Service"
APP_BUNDLE="$OUTPUT_DIR/${APP_NAME}.app"
APP_DMG="$OUTPUT_DIR/XCodeMCPService.dmg"
APP_DMG_CHECKSUM="${APP_DMG}.sha256"
APP_ARCHIVE="$OUTPUT_DIR/XCodeMCPService.app.zip"
APP_ARCHIVE_CHECKSUM="${APP_ARCHIVE}.sha256"
DMG_STAGING_DIR="$OUTPUT_DIR/dmg-root"
EXECUTABLE="XCodeMCPStatusBar"
CLI_EXECUTABLE="XCodeMCPService"
STATUS_BAR_IDENTIFIER="com.ljh740.XCodeMCPStatusBar"
CLI_IDENTIFIER="com.ljh740.XCodeMCPService"
ENTITLEMENTS_PATH="$PROJECT_DIR/Sources/XCodeMCPStatusBar/XCodeMCPService.entitlements"

sign_path() {
    local target_path="$1"
    local identifier="$2"
    local entitlements_path="${3:-}"
    local -a sign_args=(
        --force
        --sign "$CODE_SIGN_IDENTITY"
        --identifier "$identifier"
    )

    if [ -n "$entitlements_path" ]; then
        sign_args+=(--entitlements "$entitlements_path")
    fi

    if [ "$CODE_SIGN_RUNTIME" = "1" ]; then
        sign_args+=(--options runtime)
    fi

    case "$CODE_SIGN_TIMESTAMP" in
        auto)
            if [ "$CODE_SIGN_IDENTITY" = "-" ]; then
                sign_args+=(--timestamp=none)
            else
                sign_args+=(--timestamp)
            fi
            ;;
        secure)
            sign_args+=(--timestamp)
            ;;
        none)
            sign_args+=(--timestamp=none)
            ;;
        *)
            echo "Error: CODE_SIGN_TIMESTAMP must be auto, secure, or none" >&2
            exit 1
            ;;
    esac

    codesign "${sign_args[@]}" "$target_path"
}

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

# 8. 先签内层可执行文件，再签整个 App bundle；未指定 identity 时使用 ad-hoc 签名
echo "=== Signing ${APP_NAME}.app ==="
if [ "$CODE_SIGN_IDENTITY" = "-" ]; then
    echo "Using ad-hoc signing; Xcode may still grant only temporary agent trust"
else
    echo "Using code signing identity: $CODE_SIGN_IDENTITY"
fi
sign_path "$APP_BUNDLE/Contents/MacOS/$CLI_EXECUTABLE" "$CLI_IDENTIFIER" "$ENTITLEMENTS_PATH"
sign_path "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" "$STATUS_BAR_IDENTIFIER" "$ENTITLEMENTS_PATH"
sign_path "$APP_BUNDLE" "$STATUS_BAR_IDENTIFIER" "$ENTITLEMENTS_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
echo "Code signing verification passed"

# 9. 打包 zip 并生成校验文件
rm -f "$APP_DMG" "$APP_DMG_CHECKSUM" "$APP_ARCHIVE" "$APP_ARCHIVE_CHECKSUM"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$APP_ARCHIVE"
shasum -a 256 "$APP_ARCHIVE" > "$APP_ARCHIVE_CHECKSUM"

# 10. 打包 dmg 并生成校验文件
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
