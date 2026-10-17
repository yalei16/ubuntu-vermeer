#!/usr/bin/env bash
# 13-make-vendor-boot.sh —— 用原厂 vendor_boot.img 做模板，生成带主线 DTB 的 vendor_boot.img
#
# 为什么必须有这一步（2026-10-17 用原厂镜像实测得出）：
#   K70 的原厂 boot.img 里 **没有** DTB（内核区间搜不到 FDT 魔数），DTB 在
#   vendor_boot.img 里（实测：dtb_size=3885971，dtb 物理地址 0x1f00000）。
#   也就是说 ABL 是从 vendor_boot 取设备树的 —— 只刷 boot.img 的话，
#   ABL 会把 **Android 的设备树**交给主线内核，面板/UFS 节点对不上，表现为黑屏。
#
# 因此本脚本把原厂 vendor_boot 拆开（vendor_ramdisk / dtb / bootconfig），
# 换成主线的 DTB 再按原样打包，产出两个变体：
#   * vendor_boot-vermeer-noramdisk.img —— **不带** vendor_ramdisk（首选）：
#     内核没有 initramfs，直接按 cmdline 的 root=PARTLABEL=... 挂 rootfs
#   * vendor_boot-vermeer-stockrd.img   —— 保留原厂 Android ramdisk（备用）：
#     如果 ABL 拒绝空 ramdisk 才用它；但它会让 Android 的 init 先跑，主线大概率起不来
#
# 用法:
#   scripts/host/13-make-vendor-boot.sh \
#       --stock vendor_boot.img \
#       --dtb   build/arch/arm64/boot/dts/qcom/sm8550-xiaomi-vermeer.dtb \
#       [--out-dir out] [--both]
#
# 依赖：仓库内的 mkbootimg + python3 + scripts/host/12-analyze-bootimg.py
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"
# shellcheck source=../common/device-env.sh
source "$HERE/../common/device-env.sh"

PY="${PYTHON:-python3}"

# Windows（git-bash/MSYS）下把路径转成原生形式，否则 python.exe 会把 /d/work/...
# 解释成 D:\d\work\...（Linux 上 cygpath 不存在，函数原样返回）
to_native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
STOCK=""
DTB=""
OUT_DIR="out"
BOTH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stock) STOCK="$2"; shift 2 ;;
    --dtb)   DTB="$2";   shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --both)  BOTH=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[[ -n "$STOCK" ]] || die "必须给 --stock <原厂 vendor_boot.img>"
[[ -f "$STOCK" ]] || die "文件不存在: $STOCK"
[[ -n "$DTB" ]]   || die "必须给 --dtb <编出来的 sm8550-xiaomi-vermeer.dtb>"
[[ -f "$DTB" ]]   || die "文件不存在: $DTB"
[[ -f "$REPO_ROOT/mkbootimg" ]] || die "仓库内缺少 mkbootimg"

# 交给 python 的路径统一转成原生形式（Windows 下必需）
ANALYZER="$(to_native "$HERE/12-analyze-bootimg.py")"
MKBOOTIMG_BIN="$(to_native "$REPO_ROOT/mkbootimg")"
STOCK="$(to_native "$STOCK")"
DTB="$(to_native "$DTB")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR"

log "拆解原厂 vendor_boot: $STOCK"
# shellcheck disable=SC2046
eval "$("$PY" "$ANALYZER" "$STOCK" --extract "$(to_native "$WORK")" --shell)"

[[ "$VB_HEADER_VERSION" == "4" ]] || die "只支持 vendor_boot header v4（实测这是 K70 的形态），当前 $VB_HEADER_VERSION"
[[ -f "$WORK/vendor_ramdisk" ]] || warn "原厂 vendor_boot 里没有 vendor_ramdisk（不影响无 ramdisk 变体）"
[[ -f "$WORK/bootconfig" ]] || die "没有从原厂 vendor_boot 里取到 bootconfig"

log "原厂参数: pagesize=$VB_PAGESIZE kernel_addr=$VB_KERNEL_ADDR ramdisk_addr=$VB_RAMDISK_ADDR tags_addr=$VB_TAGS_ADDR dtb_addr=$VB_DTB_ADDR"
log "原厂 dtb_size=$VB_DTB_SIZE，主线 DTB=$(du -h "$DTB" | cut -f1)"

chmod +x "$REPO_ROOT/mkbootimg"

build_variant() {
  local out="$1"; shift
  local extra=("$@")
  log "生成 $out"
  "$PY" "$MKBOOTIMG_BIN" \
    --vendor_boot "$(to_native "$out")" \
    --header_version 4 \
    --pagesize "$VB_PAGESIZE" \
    --base 0 \
    --kernel_offset "$VB_KERNEL_ADDR" \
    --ramdisk_offset "$VB_RAMDISK_ADDR" \
    --tags_offset "$VB_TAGS_ADDR" \
    --dtb "$DTB" \
    --dtb_offset "$VB_DTB_ADDR" \
    --vendor_cmdline "$VB_VENDOR_CMDLINE" \
    --vendor_bootconfig "$(to_native "$WORK/bootconfig")" \
    "${extra[@]}"

  # 自检：重新解析产物，确认 dtb 是我们的、页大小与原厂一致
  # shellcheck disable=SC2046
  eval "$("$PY" "$ANALYZER" "$(to_native "$out")" --shell)"
  [[ "$VB_PAGESIZE" == "4096" ]] || die "$out 的 pagesize 不是 4096"
  local our_dtb_size
  our_dtb_size="$(stat -c '%s' "$DTB" 2>/dev/null || wc -c < "$DTB" | tr -d ' ')"
  [[ "$VB_DTB_SIZE" == "$our_dtb_size" ]] \
    || die "$out 里的 DTB 大小($VB_DTB_SIZE) 与输入($our_dtb_size) 不一致"
  log "  ✓ 产物校验通过: header v$VB_HEADER_VERSION pagesize=$VB_PAGESIZE dtb_size=$VB_DTB_SIZE dtb_addr=$VB_DTB_ADDR vendor_ramdisk=$VB_VENDOR_RAMDISK_SIZE"
}

# 首选：不带 vendor_ramdisk（主线不要 Android 的 init）
build_variant "$OUT_DIR/vendor_boot-vermeer-noramdisk.img"

# 备用：保留原厂 ramdisk
if [[ "$BOTH" -eq 1 || ! -f "$WORK/vendor_ramdisk" ]]; then
  if [[ -f "$WORK/vendor_ramdisk" ]]; then
    build_variant "$OUT_DIR/vendor_boot-vermeer-stockrd.img" \
      --vendor_ramdisk "$(to_native "$WORK/vendor_ramdisk")"
  fi
fi

cat <<EOF

完成。产物：
  $OUT_DIR/vendor_boot-vermeer-noramdisk.img   ← 先试这个
$( [[ -f "$OUT_DIR/vendor_boot-vermeer-stockrd.img" ]] && echo "  $OUT_DIR/vendor_boot-vermeer-stockrd.img     ← 备用（保留 Android ramdisk）" )

刷写（写到非当前槽，保证 Android 那一槽完好）：
  fastboot flash vendor_boot_b $OUT_DIR/vendor_boot-vermeer-noramdisk.img
  fastboot flash boot_b        boot.img
  fastboot set_active b

回滚：
  fastboot flash vendor_boot_b stock-vendor_boot.img
  fastboot flash boot_b        stock-boot.img
EOF
