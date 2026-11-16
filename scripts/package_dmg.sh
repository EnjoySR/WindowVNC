#!/bin/bash
# 打成可拖拽安装的 DMG。
#
# 公证说明：
#   要让别人的 Mac 不弹「无法验证开发者」，必须满足两个条件——
#     1. 用 Developer ID Application 证书签名（需要付费 Apple Developer 账号）
#     2. 提交 Apple 公证并 staple
#   两者缺一不可。Apple Development 证书做不到，ad-hoc 更不行。
#
#   有了账号之后，先存一次凭据：
#     xcrun notarytool store-credentials WindowVNC-Notary \
#       --apple-id <你的AppleID> --team-id <TeamID> --password <App专用密码>
#   然后这样打包：
#     CODESIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" \
#     NOTARY_PROFILE=WindowVNC-Notary ./scripts/package_dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Bundle/Info.plist)
APP="build/WindowVNC.app"
STAGE="build/dmg-stage"
DMG="dist/WindowVNC-${VERSION}.dmg"

./build_app.sh release

SIGNED_BY=$(codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2- || echo "未知")
NOTARIZED=no

# 公证（只有配置了 NOTARY_PROFILE 才走）
if [ -n "${NOTARY_PROFILE:-}" ]; then
  if ! codesign -dvv "$APP" 2>&1 | grep -q "Developer ID Application"; then
    echo "错误：公证要求用 Developer ID Application 证书签名，当前是「$SIGNED_BY」" >&2
    echo "      请设置 CODESIGN_IDENTITY 后重试。" >&2
    exit 1
  fi
  echo "==> 提交公证（几分钟）…"
  ditto -c -k --keepParent "$APP" build/WindowVNC-notarize.zip
  xcrun notarytool submit build/WindowVNC-notarize.zip \
        --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  NOTARIZED=yes
fi

# 组装 DMG 内容：App + 「应用程序」软链，拖过去即安装
rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/应用程序"

# 没公证的话，附一份首次打开说明
if [ "$NOTARIZED" != yes ]; then
  cat > "$STAGE/首次打开说明.txt" <<'TXT'
这个版本没有经过 Apple 公证，首次打开会提示「无法验证开发者」。

处理办法（两选一）：

一、图形界面
   1. 把 WindowVNC 拖到「应用程序」
   2. 双击打开，出现警告后点「完成」
   3. 打开 系统设置 → 隐私与安全性，向下滚动
   4. 会看到「已阻止使用 WindowVNC」，点右边的「仍要打开」

二、终端一条命令
   xattr -dr com.apple.quarantine /Applications/WindowVNC.app

装好后还需要授予屏幕录制权限：
   系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 WindowVNC
   勾选后需要重新打开 WindowVNC 才生效。
TXT
fi

rm -f "$DMG"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg --volname "WindowVNC" --window-size 560 380 --icon-size 110 \
             --icon "WindowVNC.app" 150 170 --icon "应用程序" 410 170 \
             --no-internet-enable "$DMG" "$STAGE" >/dev/null
else
  # 没装 create-dmg 就用系统自带的 hdiutil，布局朴素但功能一样
  hdiutil create -volname "WindowVNC" -srcfolder "$STAGE" \
                 -ov -format UDZO "$DMG" >/dev/null
fi

# DMG 本身也签一下，公证时是连 DMG 一起验证的
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$DMG"
fi

echo
echo "===================================="
echo "  产物 : $DMG  ($(du -h "$DMG" | cut -f1))"
echo "  版本 : $VERSION"
echo "  签名 : $SIGNED_BY"
[ "$NOTARIZED" = yes ] && echo "  公证 : 已公证"
echo "===================================="
