#!/bin/bash
# AnchorScroll — 生成可分发的 macOS 安装镜像（.dmg）
#
# 用法：
#   bash make-dmg.sh              # 默认输出 release/AnchorScroll-<版本>-macOS-arm64.dmg
#   ANCHORSCROLL_DMG_OUTPUT=/path/to/x.dmg bash make-dmg.sh
#   ANCHORSCROLL_APP_SOURCE=/path/to/AnchorScroll.app bash make-dmg.sh   # 跳过构建，直接打包已有 .app
#
# 产物：UDZO 压缩 DMG，内含 AnchorScroll.app、指向 /Applications 的快捷方式及安装说明。

set -euo pipefail
cd "$(dirname "$0")"

APP_SOURCE="${ANCHORSCROLL_APP_SOURCE:-dist/AnchorScroll.app}"

# 1. 必要时先构建（构建脚本自带内核测试与 ad-hoc 签名校验）
if [ ! -d "$APP_SOURCE" ]; then
  echo "==> 未找到 ${APP_SOURCE}，先执行 build.sh"
  bash build.sh
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_SOURCE/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_SOURCE/Contents/Info.plist")
VOLNAME="AnchorScroll ${VERSION}"
DMG_NAME="AnchorScroll-${VERSION}-macOS-arm64.dmg"
OUT="${ANCHORSCROLL_DMG_OUTPUT:-release/$DMG_NAME}"

mkdir -p "$(dirname "$OUT")"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# 2. 组装安装镜像内容
echo "==> 准备镜像内容（${VOLNAME} / build ${BUILD}）"
ditto "$APP_SOURCE" "$STAGE/AnchorScroll.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<'TXT'
AnchorScroll 安装说明
====================

1. 将左侧的 AnchorScroll.app 拖入右侧的 Applications（应用程序）文件夹。
2. 打开「应用程序」中的 AnchorScroll，按系统提示前往
   系统设置 → 隐私与安全性 → 辅助功能，勾选 AnchorScroll。
3. 若更新版本后权限失效，请在辅助功能列表中移除旧的 AnchorScroll 条目，
   重新添加当前应用，然后重启应用或点击菜单栏图标中的「权限检查 / 重试」。

使用方式
--------
点按（不要按住拖动）鼠标中键后松开，以点击位置为速度中心：
鼠标离中心越近滚动越慢，越远越快；停在偏移位置持续滚动，回到中心即停止。
点击鼠标左键或按 Esc 退出本次自动滚动。

首次打开提示
------------
本应用为本机 ad-hoc 签名，未使用 Developer ID 签名、未经 Apple 公证，
首次打开时 macOS 可能提示「无法验证开发者」。请右键点击应用图标选择
「打开」，或在系统设置的「隐私与安全性」中点击「仍要打开」。
请勿通过关闭系统安全功能来安装。
TXT

# 3. 生成 DMG
echo "==> 生成 $OUT"
rm -f "$OUT"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$OUT" >/dev/null

# 4. 校验：挂载 → 核对应用与快捷方式 → 卸载
echo "==> 校验镜像"
MOUNT_POINT=$(hdiutil attach "$OUT" -nobrowse -readonly | grep -o '/Volumes/.*' | head -1)
if [ -z "$MOUNT_POINT" ]; then
  echo "镜像挂载失败" >&2
  exit 1
fi
trap 'hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true; rm -rf "$STAGE"' EXIT

test -d "$MOUNT_POINT/AnchorScroll.app" || { echo "镜像内缺少 AnchorScroll.app" >&2; exit 1; }
test -L "$MOUNT_POINT/Applications" || { echo "镜像内缺少 Applications 快捷方式" >&2; exit 1; }
codesign --verify --deep --strict "$MOUNT_POINT/AnchorScroll.app"
MOUNTED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$MOUNT_POINT/AnchorScroll.app/Contents/Info.plist")
[ "$MOUNTED_VERSION" = "$VERSION" ] || { echo "版本不一致：$MOUNTED_VERSION != $VERSION" >&2; exit 1; }

hdiutil detach "$MOUNT_POINT" >/dev/null
echo "==> 完成：${OUT}（版本 ${VERSION}，build ${BUILD}）"
shasum -a 256 "$OUT"
