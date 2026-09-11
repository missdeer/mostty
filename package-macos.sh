#!/bin/bash

set -euo pipefail

# ====== 用户配置部分 ======
APP_NAME="Mostty.app"
VOLNAME="Mostty"
BG_NAME="dmg-background.tiff"
SIGN_ID="${SIGN_ID:-Developer ID Application: Fan Yang (Y73SBCN2CG)}"
# 用 xcrun notarytool store-credentials <name> 建好凭据后，把名字填在这里或用环境变量覆盖
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
# ==========================

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="$SCRIPT_DIR"

SRC_APP="${1:-$ROOT_DIR/zig-out/$APP_NAME}"
DIST_DIR="$ROOT_DIR/zig-out/dist-macos"
OUT_APP="$DIST_DIR/$APP_NAME"
DMG_FINAL="$DIST_DIR/${APP_NAME%.app}.dmg"

if [ ! -d "$SRC_APP" ]; then
    echo "❌ 找不到 app bundle: $SRC_APP"
    echo "   先运行 zig build，或把 .app 路径作为第一个参数传进来。"
    exit 1
fi

if [ -z "$NOTARY_PROFILE" ]; then
    echo "❌ 未设置 NOTARY_PROFILE（notarytool 钥匙串凭据名）。"
    echo "   先创建一次：xcrun notarytool store-credentials <name> \\"
    echo "                 --apple-id <apple-id> --team-id Y73SBCN2CG --password <app-专用密码>"
    echo "   然后：NOTARY_PROFILE=<name> $0"
    exit 1
fi

if [ ! -x "$SRC_APP/Contents/MacOS/Mostty" ] || [ ! -f "$SRC_APP/Contents/Info.plist" ]; then
    echo "❌ 不是完整的 Mostty app bundle: $SRC_APP"
    exit 1
fi

# 避免传入上次的输出目录时，先删掉源 app 再复制。
SRC_APP=$(cd "$SRC_APP" && pwd -P)
if [ -d "$OUT_APP" ] && [ "$SRC_APP" = "$(cd "$OUT_APP" && pwd -P)" ]; then
    echo "❌ 源 app 不能是打包输出: $OUT_APP"
    exit 1
fi

mkdir -p "$ROOT_DIR/tmp"
WORK_DIR=$(mktemp -d "$ROOT_DIR/tmp/package-macos.XXXXXX")
APP_ZIP="$WORK_DIR/${APP_NAME%.app}.zip"
DMG_TEMP="$WORK_DIR/tmp.dmg"
DMG_CONTENTS="$WORK_DIR/dmg-contents"
MOUNT_DIR="$WORK_DIR/mount"
MOUNTED_BY_US=""

cleanup() {
    if [ -n "$MOUNTED_BY_US" ]; then
        # 卸载失败时保留工作目录，不能递归删除仍挂载的卷。
        hdiutil detach "$MOUNT_DIR" -force -quiet || return
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ====== 部署 ======

echo "📦 Staging app bundle to $DIST_DIR"
mkdir -p "$DIST_DIR"
rm -rf "$OUT_APP"
cp -R "$SRC_APP" "$OUT_APP"

echo "🏗  Architectures:"
lipo -info "$OUT_APP/Contents/MacOS/${APP_NAME%.app}"

# 残留的 quarantine / resource-fork 扩展属性会让 codesign 失败
xattr -cr "$OUT_APP"

# ====== 签名 ======

sign_one() {
    codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$1"
}

# Mostty 静态链接 Zig core，仅依赖系统 frameworks，无需部署 Qt 或嵌套库。
echo "🔏 Signing app bundle..."
sign_one "$OUT_APP"

codesign --verify --deep --strict --verbose=2 "$OUT_APP"
echo "✅ Code signature valid"

# ====== 公证 ======

echo "📦 Zipping app for notarization..."
ditto -c -k --sequesterRsrc --keepParent "$OUT_APP" "$APP_ZIP"

echo "☁️  Submitting app to Apple Notary Service..."
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "📩 Stapling notarization ticket to app..."
xcrun stapler staple "$OUT_APP"
xcrun stapler validate "$OUT_APP"

spctl --assess --type execute --verbose=2 "$OUT_APP"
echo "✅ Gatekeeper accepts the app"

# ====== 打包 DMG ======

echo "📀 Creating DMG..."
mkdir -p "$DMG_CONTENTS"

cp -R "$OUT_APP" "$DMG_CONTENTS/"
ln -s /Applications "$DMG_CONTENTS/Applications"
if [ -f "$SCRIPT_DIR/$BG_NAME" ]; then
    mkdir -p "$DMG_CONTENTS/.background"
    cp "$SCRIPT_DIR/$BG_NAME" "$DMG_CONTENTS/.background/$BG_NAME"

    hdiutil create -volname "$VOLNAME" -srcfolder "$DMG_CONTENTS" -ov -format UDRW -fs HFS+ "$DMG_TEMP"
    hdiutil attach "$DMG_TEMP" -mountpoint "$MOUNT_DIR" -nobrowse
    MOUNTED_BY_US=1

    # 背景图尺寸与下面的窗口 bounds 一一对应；改图后要一起改。
    # 重新生成：rsvg-convert -w 500 -h 300 dmg-background.svg -o 1x.png &&
    #           rsvg-convert -w 1000 -h 600 dmg-background.svg -o 2x.png &&
    #           tiffutil -cathidpicheck 1x.png 2x.png -out dmg-background.tiff
    echo "🎨 Configuring DMG window..."
    osascript <<EOF
tell application "Finder"
    tell folder (POSIX file "$MOUNT_DIR" as alias)
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- 高度 328 = 背景图 300 + 28 像素标题栏，bounds 含标题栏，写 300 会把图底部裁掉
        set the bounds of container window to {400, 100, 900, 428}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:$BG_NAME"
        set position of item "$APP_NAME" of container window to {112, 150}
        set position of item "Applications" of container window to {388, 150}
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

    sync

    # osascript 退出码不足以说明排版生效：自动化权限被拒时它也可能悄悄什么都没做。
    # 认准 Finder 是否真把背景图写进了 .DS_Store。
    if ! rg -a -q 'backgroundImageAlias' "$MOUNT_DIR/.DS_Store" 2>/dev/null; then
        echo "❌ Finder 没有写入窗口排版，DMG 会是默认白底无背景图。"
        echo "   多半是系统设置 → 隐私与安全性 → 自动化 里没给当前终端控制「访达」的权限。"
        exit 1
    fi

    hdiutil detach "$MOUNT_DIR" || {
        sleep 2
        hdiutil detach "$MOUNT_DIR" -force
    }
    MOUNTED_BY_US=""

    hdiutil convert "$DMG_TEMP" -format UDZO -o "$WORK_DIR/Mostty.dmg"
else
    echo "ℹ️  未提供 ${BG_NAME}，生成无背景图的 DMG。"
    hdiutil create -volname "$VOLNAME" -srcfolder "$DMG_CONTENTS" -format UDZO -fs HFS+ "$WORK_DIR/Mostty.dmg"
fi

echo "🔏 Signing DMG..."
codesign --force --timestamp --sign "$SIGN_ID" "$WORK_DIR/Mostty.dmg"

echo "☁️  Submitting DMG to Apple Notary Service..."
xcrun notarytool submit "$WORK_DIR/Mostty.dmg" --keychain-profile "$NOTARY_PROFILE" --wait

echo "📩 Stapling notarization ticket to DMG..."
xcrun stapler staple "$WORK_DIR/Mostty.dmg"
xcrun stapler validate "$WORK_DIR/Mostty.dmg"
mv -f "$WORK_DIR/Mostty.dmg" "$DMG_FINAL"

echo "🎉 Done:"
echo "➡️  $OUT_APP"
echo "➡️  $DMG_FINAL"
