#!/usr/bin/env bash
# 打包 firmware-xiaomi-vermeer（K70 / POCO F6 Pro 的固件 blob 与配置）
#
# 与 sheng 版本的差别：
#   * 上游固件仓库从 ianchb/sheng-firmware 换成 XEC 的 linux-firmware-xiaomi-vermeer
#   * 该仓库把固件放在子目录 xiaomi-vermeer/ 下（ath12k/、qcom/），
#     而 sheng 的仓库根就是固件根 —— 必须只铺子目录内容，否则设备上
#     会出现 /usr/lib/firmware/xiaomi-vermeer/ath12k/... 这种驱动永远找不到的路径
#
# 需要环境变量：
#   FIRMWARE_REPO    固件仓库 URL（默认见 device-env.sh）
#   FIRMWARE_BRANCH  分支（默认 main）
#   FIRMWARE_SUBDIR  固件在仓库里的子目录（默认 xiaomi-vermeer；留空=仓库根）
#
# 用法: scripts/packages/build-firmware.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/device-env.sh
source "$HERE/../common/device-env.sh"

PKG="$FIRMWARE_DEB"
FIRMWARE_REPO="${FIRMWARE_REPO:-$DEFAULT_FIRMWARE_REPO}"
FIRMWARE_BRANCH="${FIRMWARE_BRANCH:-$DEFAULT_FIRMWARE_BRANCH}"
FIRMWARE_SUBDIR="${FIRMWARE_SUBDIR:-xiaomi-vermeer}"

PKDIR="$(cd "$HERE/../.." && pwd)/$PKG"
OUT="${PWD}/${PKG}.deb"
BUILD="${PWD}/build/${PKG}"
SRC="${PWD}/build/firmware-src"

rm -rf "$BUILD" "$SRC"
mkdir -p "$BUILD/usr/lib/firmware"

echo "[build-firmware] 克隆 $FIRMWARE_REPO ($FIRMWARE_BRANCH)"
git clone --depth 1 --branch "$FIRMWARE_BRANCH" "$FIRMWARE_REPO" "$SRC"

FWROOT="$SRC"
if [[ -n "$FIRMWARE_SUBDIR" ]]; then
  FWROOT="$SRC/$FIRMWARE_SUBDIR"
  [[ -d "$FWROOT" ]] || {
    echo "[build-firmware] 固件子目录不存在: $FWROOT" >&2
    echo "[build-firmware] 仓库根内容：$(ls -1 "$SRC" | tr '\n' ' ')" >&2
    exit 1
  }
fi

cp -a "$FWROOT/." "$BUILD/usr/lib/firmware/"
rm -rf "$BUILD/usr/lib/firmware/.git" \
       "$BUILD/usr/lib/firmware/.github" \
       "$BUILD/usr/lib/firmware/.gitignore"

# 固件 blob 必须保持原样：不做 strip、不压缩
find "$BUILD" -type d -exec chmod 755 {} +
find "$BUILD" -type f -exec chmod 644 {} +

cp -a "$PKDIR/DEBIAN" "$BUILD/"
dpkg-deb --build --root-owner-group "$BUILD" "$OUT"
echo "[build-firmware] 产出 $OUT ($(du -h "$OUT" | cut -f1))"
find "$BUILD/usr/lib/firmware" -maxdepth 1 -mindepth 1 -printf '    %f\n' | sort
