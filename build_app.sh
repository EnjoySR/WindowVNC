#!/bin/bash
# 把 SwiftPM 产物打包成 WindowVNC.app 并签名。
#
# 关于签名身份：TCC 的「屏幕录制」授权绑定代码签名身份。用固定证书签名后，
# 每次重新编译不会掉权限；ad-hoc 签名每次编译的 cdhash 都变，系统会当成新 App
# 反复索要权限。所以这里默认用 Apple Development 证书。
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"   # 性能敏感，默认 Release。Debug 构建不消除数组边界检查也不内联，编码循环会慢一个数量级
# 签名身份的选取顺序：环境变量 > Developer ID > 任一 Apple Development > ad-hoc。
# 不写死证书哈希——Apple Development 证书一年就过期，写死的值失效后脚本会直接挂。
PREFERRED_SIGNER="${PREFERRED_SIGNER:-yinqiaoyin}"   # 机器上有多人的证书，优先挑自己的
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning \
             | grep "Developer ID Application" | head -1 | awk '{print $2}') || true
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning \
             | grep "$PREFERRED_SIGNER" | head -1 | awk '{print $2}') || true
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning \
             | grep "Apple Development" | head -1 | awk '{print $2}') || true
fi
if [ -z "$IDENTITY" ]; then
  # ad-hoc 兜底：能跑，但每次重新编译 cdhash 都变，
  # 系统会当成新 App，屏幕录制权限要反复重授
  IDENTITY="-"
  echo "⚠️  钥匙串里没有可用的签名证书，退回 ad-hoc 签名。"
  echo "    后果：每次重新编译都要重新授予「屏幕录制」权限。"
fi
echo "==> 签名身份: $(security find-identity -v -p codesigning | grep "$IDENTITY" | sed 's/.*"\(.*\)"/\1/' || echo ad-hoc)"

APP="build/WindowVNC.app"

# 图标：没有就现生成
if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make_icon.swift "$PWD" >/dev/null
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

# 通用二进制（Apple Silicon + Intel）。
# 不能用 `swift build --arch arm64 --arch x86_64` 一次编完——CZlib 这个 system
# library 目标在双架构模式下会产生同名输出文件，报 "duplicate output file"。
# 所以两个架构分别编到各自的 scratch 目录，再用 lipo 合并。
SLICES=()
for ARCH in arm64 x86_64; do
  echo "==> 编译 $ARCH"
  swift build -c "$CONFIG" --arch "$ARCH" --scratch-path ".build-$ARCH" >/dev/null
  SLICES+=(".build-$ARCH/$( [ "$CONFIG" = release ] && echo release || echo debug )/WindowVNCApp")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Bundle/Info.plist "$APP/Contents/Info.plist"
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/WindowVNCApp"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 自定义「指定要求」：只锁 Team ID，不锁具体那张证书。
#
# codesign 默认生成的要求里写死了 certificate leaf[subject.CN]，而 CN 里带着
# 证书的唯一 ID。Apple Development 证书一年一换，换一次 CN 就变，TCC 就把
# App 当成新的，「屏幕录制」权限要重授一次。改成只匹配 subject.OU（即 Team ID）
# 之后，同一个开发者账号签发的新证书仍然满足要求，权限不会掉。
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Bundle/Info.plist)
REQ_ARG=()
if [ "$IDENTITY" != "-" ]; then
  IDNAME=$(security find-identity -v -p codesigning | grep "$IDENTITY" \
           | sed 's/.*"\(.*\)"/\1/')
  TEAM=$(security find-certificate -c "$IDNAME" -p 2>/dev/null \
         | openssl x509 -noout -subject 2>/dev/null \
         | tr ',' '\n' | grep -E '^ *OU *=' | head -1 | sed 's/.*= *//')
  if [ -n "$TEAM" ]; then
    REQ_ARG=(-r="designated => identifier \"$BUNDLE_ID\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */ and certificate leaf[subject.OU] = \"$TEAM\"")
    echo "==> 指定要求锁定 Team ID: ${TEAM} (证书续期不会导致权限失效)"
  fi
fi

# --options runtime 是公证的硬性要求，现在就加上，将来接公证不用改
codesign --force --options runtime --timestamp=none \
         --sign "$IDENTITY" ${REQ_ARG[@]+"${REQ_ARG[@]}"} "$APP"

echo "已打包并签名: $APP"
lipo -info "$APP/Contents/MacOS/WindowVNCApp"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|TeamIdentifier|Signature' || true
