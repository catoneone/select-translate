#!/bin/bash
# 构建 SelectTranslate.app（划线翻译）
#
# 用法：
#   ./build.sh              构建到 build/SelectTranslate.app
#   ./build.sh --install    构建并安装到 /Applications，然后启动
#   ./build.sh --zip        构建并打包 build/SelectTranslate-<版本>.zip（用于发布）
#
# 环境变量（可选）：
#   ARCHS="arm64 x86_64"    目标架构（默认通用二进制）
#   VERSION=1.0.0           版本号（默认取 git tag）
#   SIGN_ID=<证书名或SHA1>  代码签名证书；未设置则使用 ad-hoc 签名
#   SIGN_KEYCHAIN=<路径>    证书所在钥匙串（可选）
#   SIGN_KEYCHAIN_PASSWORD  该钥匙串的密码（可选）
# 也可以把以上变量写在 signing/local.env 中（已加入 .gitignore）。
set -euo pipefail
cd "$(dirname "$0")"

[[ -f signing/local.env ]] && source signing/local.env

NAME="SelectTranslate"
DISPLAY_NAME="划线翻译"
BUNDLE_ID="io.github.catoneone.selecttranslate"
ARCHS="${ARCHS:-arm64 x86_64}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

APP="build/$NAME.app"
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

SOURCES=$(find Sources -name '*.swift' | sort)
BINS=()
for arch in $ARCHS; do
  echo "▸ 编译 ${arch} …"
  # shellcheck disable=SC2086
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    -o "build/obj/$NAME-$arch" $SOURCES \
    -framework Cocoa -framework ApplicationServices -framework Security
  BINS+=("build/obj/$NAME-$arch")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/$NAME"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUM</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# 代码签名。ad-hoc 签名每次构建都会变化，macOS 会认为是新应用，需要重新授予「辅助功能」权限；
# 使用固定证书签名（哪怕是自签名）则授权可以在重新构建后保留。
if [[ -n "${SIGN_ID:-}" ]]; then
  echo "▸ 使用证书签名：${SIGN_ID}"
  if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
    ORIG_KCS=()
    while IFS= read -r line; do ORIG_KCS+=("$(echo "$line" | tr -d '" ')"); done < <(security list-keychains -d user)
    restore_kcs() { security list-keychains -d user -s "${ORIG_KCS[@]}"; }
    trap restore_kcs EXIT
    [[ -n "${SIGN_KEYCHAIN_PASSWORD:-}" ]] && security unlock-keychain -p "$SIGN_KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN"
    security list-keychains -d user -s "${ORIG_KCS[@]}" "$SIGN_KEYCHAIN"
  fi
  codesign --force -s "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
  if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then restore_kcs; trap - EXIT; fi
else
  echo "▸ 使用 ad-hoc 签名"
  codesign --force -s - --identifier "$BUNDLE_ID" "$APP"
fi
echo "✅ 构建完成：${APP}（版本 ${VERSION}，架构 ${ARCHS}）"

case "${1:-}" in
  --install)
    pkill -x "$NAME" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$NAME" >/dev/null || break; sleep 0.3; done   # 等旧进程退出
    rm -rf "/Applications/$NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$NAME.app"
    echo "✅ 已安装到 /Applications 并启动"
    ;;
  --zip)
    ZIP="build/$NAME-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "✅ 已打包：${ZIP}"
    ;;
esac
