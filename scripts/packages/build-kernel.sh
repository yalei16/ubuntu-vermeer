#!/usr/bin/env bash
# custom_build：用 XEC 的 vermeer 内核树编译内核，打成 deb + mkbootimg 用的拼接镜像
#
# 与 sheng 版本的差别（这里是移植的核心之一）：
#   * sheng 的上游内核仓库自带一份可直接 install 成 .config 的 sm8550.config；
#     XEC 树没有 vermeer 的 defconfig，只有 defconfig + sm8550.config + hardening.config
#     三个**片段**，因此必须走 scripts/kconfig/merge_config.sh 合并（见 docs/移植对照.md）
#   * sheng 树产出 Image.gz；XEC 树文档化的产物是未压缩的 Image，这里统一
#     `make Image` 后自己 gzip，避免依赖 CONFIG_KERNEL_GZIP
#   * 产物名 / deb 名 → linux-xiaomi-vermeer、Image.gz-dtb_vermeer
#
# 需要环境变量（均有默认值，见 scripts/common/device-env.sh）：
#   KERNEL_REPO / KERNEL_BRANCH
#   KERNEL_CONFIG_FRAGMENTS（树内片段，空格分隔）
#   KERNEL_EXTRA_CONFIG（本仓库片段，相对仓库根）
#
# 用法: scripts/packages/build-kernel.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/device-env.sh
source "$HERE/../common/device-env.sh"

KERNEL_REPO="${KERNEL_REPO:-$DEFAULT_KERNEL_REPO}"
KERNEL_BRANCH="${KERNEL_BRANCH:-$DEFAULT_KERNEL_BRANCH}"
KERNEL_CONFIG_FRAGMENTS="${KERNEL_CONFIG_FRAGMENTS:-sm8550.config hardening.config}"
KERNEL_EXTRA_CONFIG="${KERNEL_EXTRA_CONFIG:-vermeer-extra.config}"

REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SRC="${PWD}/linux"
PKGDIR="${PWD}/${KERNEL_DEB}"
OUT="${PWD}/${KERNEL_DEB}.deb"
JOINED="${PWD}/${DEVICE_KERNEL_IMAGE}"

rm -rf "$SRC" "$PKGDIR"
echo "[build-kernel] 克隆 $KERNEL_REPO ($KERNEL_BRANCH)"
git clone "$KERNEL_REPO" --branch "$KERNEL_BRANCH" --depth 1 "$SRC"

# ── 设备树检查：拿错分支/拿错树时立刻停下，而不是编完 40 分钟才发现没 DTB ─────
DTB_PATH="$SRC/arch/arm64/boot/dts/qcom/${DEVICE_DTB%.dtb}.dts"
[[ -f "$DTB_PATH" ]] || {
  echo "[build-kernel] 该内核树里没有 ${DEVICE_DTB%.dtb}.dts（$DTB_PATH）" >&2
  echo "[build-kernel] 换一棵带 vermeer 的树：$DEFAULT_KERNEL_REPO@$DEFAULT_KERNEL_BRANCH" >&2
  exit 1
}

# ── 配置：defconfig → 树内片段 → 本仓库片段，全部合并后 olddefconfig ─────────
echo "[build-kernel] 生成配置（defconfig + $KERNEL_CONFIG_FRAGMENTS + $KERNEL_EXTRA_CONFIG）"
make -C "$SRC" ARCH=arm64 LLVM=1 defconfig

MERGE_ARGS=("$SRC/.config")
for frag in $KERNEL_CONFIG_FRAGMENTS; do
  f="$SRC/arch/arm64/configs/$frag"
  [[ -f "$f" ]] || { echo "[build-kernel] 缺少树内配置片段: $f" >&2; exit 1; }
  MERGE_ARGS+=("$f")
done
if [[ -n "$KERNEL_EXTRA_CONFIG" ]]; then
  extra="$REPO_ROOT/$KERNEL_EXTRA_CONFIG"
  [[ -f "$extra" ]] || { echo "[build-kernel] 缺少仓库配置片段: $extra" >&2; exit 1; }
  MERGE_ARGS+=("$extra")
fi
"$SRC/scripts/kconfig/merge_config.sh" -m -O "$SRC" "${MERGE_ARGS[@]}"
make -C "$SRC" ARCH=arm64 LLVM=1 olddefconfig

# 关键项断言：这几项没开就等于「编出来了但设备上黑屏/没有存储」
assert_cfg() {
  local sym="$1" want="$2" why="$3" val
  val="$(sed -n "s/^${sym}=//p" "$SRC/.config" | head -n1)"
  if [[ -z "$val" ]]; then
    echo "[build-kernel] 致命：$sym 未设置（$why）" >&2
    exit 1
  fi
  printf '    %-46s = %-3s (%s)\n' "$sym" "$val" "$why"
}
assert_cfg CONFIG_DRM_MSM            y "MDSS 显示主控（K70 面板经它点亮）"
assert_cfg CONFIG_DRM_PANEL_XIAOMI_N1142020A y "K70 面板驱动（N11-42-02-0A DSC）"
assert_cfg CONFIG_SCSI_UFS_QCOM      y "UFS 存储（rootfs 所在）"
assert_cfg CONFIG_ARCH_QCOM          y "QCOM 平台"
assert_cfg CONFIG_DRM_PANEL          y "DRM 面板框架"

export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
export PATH="/usr/lib/ccache:$PATH"
export CC="ccache clang"
export CXX="ccache clang++"
export AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf STRIP=llvm-strip

JOBS="$(nproc)"
echo "[build-kernel] 编译中 (JOBS=$JOBS)"
make -C "$SRC" -j"$JOBS" ARCH=arm64 LLVM=1 Image dtbs modules

KVER="$(make -C "$SRC" -s ARCH=arm64 LLVM=1 kernelrelease)"
[[ -n "$KVER" ]] || { echo "[build-kernel] 无法获取 kernelrelease" >&2; exit 1; }
echo "[build-kernel] 内核版本: $KVER"

make -C "$SRC" -j"$JOBS" ARCH=arm64 LLVM=1 INSTALL_MOD_PATH="$PKGDIR" modules_install
rm -rf "$PKGDIR/lib/modules/$KVER/build" "$PKGDIR/lib/modules/$KVER/source"

DTB="$SRC/arch/arm64/boot/dts/qcom/$DEVICE_DTB"
[[ -f "$DTB" ]] || { echo "[build-kernel] 未生成 DTB: $DTB" >&2; exit 1; }

install -Dm644 "$SRC/arch/arm64/boot/Image" "$PKGDIR/boot/vmlinuz-$KVER"
install -Dm644 "$DTB"                      "$PKGDIR/boot/dtb-$KVER.dtb"
install -Dm644 "$SRC/.config"              "$PKGDIR/boot/config-$KVER"
install -Dm644 "$SRC/System.map"           "$PKGDIR/boot/System.map-$KVER"

# mkbootimg 用的拼接镜像（Image.gz + DTB）。
# 顺序必须是「内核在前、DTB 在后」：ABL 从内核镜像尾部取 DTB，
# 同时 DTB 里的 qcom,msm-id / qcom,board-id 决定 ABL 是否选中这块板子。
gzip -9 -c "$SRC/arch/arm64/boot/Image" > "${SRC}/Image.gz"
cat "${SRC}/Image.gz" "$DTB" > "$JOINED"
echo "[build-kernel] 拼接镜像: $JOINED ($(du -h "$JOINED" | cut -f1))"

mkdir -p "$PKGDIR/DEBIAN"
cat > "$PKGDIR/DEBIAN/control" <<EOF
Package: ${KERNEL_DEB}
Version: ${KVER}
Architecture: arm64
Maintainer: yalei16
Section: kernel
Description: Kernel and modules for Xiaomi Redmi K70 / POCO F6 Pro (vermeer)
EOF

find "$PKGDIR" -type d -exec chmod 755 {} +
find "$PKGDIR" -type f -exec chmod 644 {} +

# 在包内生成 modules.dep 等索引，装机后无需再依赖 postinst
depmod -b "$PKGDIR" "$KVER" || echo "[build-kernel] 警告：depmod 失败，装机阶段会再执行一次"

dpkg-deb --build --root-owner-group "$PKGDIR" "$OUT"
echo "[build-kernel] 产出 $OUT ($(du -h "$OUT" | cut -f1))"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "kernel_version=$KVER"
    echo "kernel_image=${JOINED}"
  } >> "$GITHUB_OUTPUT"
fi
