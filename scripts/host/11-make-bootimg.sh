#!/usr/bin/env bash
# 11-make-bootimg.sh —— 用仓库内的 AOSP mkbootimg 生成 boot.img
#
# 与 sheng 版本的差别（这是移植里最容易被忽略的一处）：
#   sheng 用的是 header_version 0（mkbootimg 默认值）+ 一堆 offset，
#   vermeer 是 GKI / A/B 机型，原生 boot.img 是 header_version 4，
#   v4 头里没有 base/offset 这些字段，硬照抄 sheng 的参数会直接 `invalid boot image`。
#
#   参数一律从这里的环境变量取（由 workflow 输入传递），**不要猜**：
#   拿到 K70 线刷包里的 boot.img 后用
#       scripts/host/12-analyze-bootimg.py stock-boot.img
#   读出的值填进去即可。
#
# 环境变量：
#   PARTITION_LABEL      userdata / linux / 自定义（fstab 与 cmdline 的 root=）
#   QUIET_BOOT           true/false
#   BOOT_HEADER_VERSION  默认 4（vermeer 原生）
#   BOOT_PAGESIZE        默认 4096
#   BOOT_BASE            默认 0x00000000（仅 header_version<=2 有效）
#   BOOT_KERNEL_OFFSET   默认 0x00008000（仅 header_version<=2 有效）
#   BOOT_RAMDISK_OFFSET  默认 0x01000000（仅 header_version<=2 有效）
#   BOOT_TAGS_OFFSET     默认 0x01e00000（仅 header_version<=2 有效）
#   EXTRA_CMDLINE        追加到 cmdline 末尾（例如 earlycon 调试）
#   RAMDISK              可选；存在则作为 ramdisk 打包（本方案默认不用 initramfs）
#
# 用法: scripts/host/11-make-bootimg.sh [Image.gz-dtb_vermeer 路径]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"
# shellcheck source=../common/device-env.sh
source "$HERE/../common/device-env.sh"

KERNEL_IMAGE="${1:-$DEVICE_KERNEL_IMAGE}"
PARTITION_LABEL="${PARTITION_LABEL:?需要 PARTITION_LABEL}"
QUIET_BOOT="${QUIET_BOOT:-false}"
BOOT_HEADER_VERSION="${BOOT_HEADER_VERSION:-4}"
BOOT_PAGESIZE="${BOOT_PAGESIZE:-4096}"
BOOT_BASE="${BOOT_BASE:-0x00000000}"
BOOT_KERNEL_OFFSET="${BOOT_KERNEL_OFFSET:-0x00008000}"
BOOT_RAMDISK_OFFSET="${BOOT_RAMDISK_OFFSET:-0x01000000}"
BOOT_TAGS_OFFSET="${BOOT_TAGS_OFFSET:-0x01e00000}"
EXTRA_CMDLINE="${EXTRA_CMDLINE:-}"
RAMDISK="${RAMDISK:-}"

[[ -f "$KERNEL_IMAGE" ]] || die "内核镜像不存在: $KERNEL_IMAGE"
[[ -f mkbootimg ]] || die "仓库内缺少 mkbootimg"

# 自检：拼接镜像尾部必须是一份 FDT（DTB 魔数 0xd00dfeed）。
# 忘记拼接、或把顺序搞反（dtb 在前）时，这一步能在构建期就报出来，
# 而不是等刷完机器不开机再回头查。
if ! tail -c 65536 "$KERNEL_IMAGE" | od -An -tx1 -v | tr -d ' \n' | grep -q 'd00dfeed'; then
  warn "在 $KERNEL_IMAGE 的尾部 64 KiB 内没有找到 FDT 魔数（d00dfeed），DTB 可能没拼进去"
fi

CMDLINE="root=PARTLABEL=${PARTITION_LABEL} rootwait"
if [[ "$QUIET_BOOT" == "true" ]]; then
  CMDLINE="${CMDLINE} quiet splash plymouth.ignore-serial-consoles fbcon=map:1"
fi
if [[ -n "$EXTRA_CMDLINE" ]]; then
  CMDLINE="${CMDLINE} ${EXTRA_CMDLINE}"
fi

ARGS=(
  --kernel "$KERNEL_IMAGE"
  --cmdline "$CMDLINE"
  --header_version "$BOOT_HEADER_VERSION"
  --pagesize "$BOOT_PAGESIZE"
  -o boot.img
)
if [[ "$BOOT_HEADER_VERSION" -le 2 ]]; then
  ARGS+=(
    --base "$BOOT_BASE"
    --kernel_offset "$BOOT_KERNEL_OFFSET"
    --ramdisk_offset "$BOOT_RAMDISK_OFFSET"
    --tags_offset "$BOOT_TAGS_OFFSET"
    --id
  )
fi
if [[ -n "$RAMDISK" && -f "$RAMDISK" ]]; then
  ARGS+=(--ramdisk "$RAMDISK")
  log "打包 ramdisk: $RAMDISK"
fi

chmod +x mkbootimg
log "生成 boot.img（header_version=$BOOT_HEADER_VERSION pagesize=$BOOT_PAGESIZE）"
log "cmdline: $CMDLINE"
./mkbootimg "${ARGS[@]}"

log "boot.img 就绪: $(du -h boot.img | cut -f1)"
