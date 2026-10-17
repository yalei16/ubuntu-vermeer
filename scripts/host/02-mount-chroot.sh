#!/usr/bin/env bash
# 02-mount-chroot.sh —— 挂载虚拟文件系统并准备 chroot 环境
#
# 与上游一致：bind /dev、/dev/pts、proc、sysfs，并借用宿主 resolv.conf
# （收尾阶段会删除）。额外把仓库脚本与编译好的 deb 拷进镜像，
# 让后续步骤用 `chroot` 执行镜像内脚本，而不是在宿主上拼超长命令行。
#
# 用法: sudo scripts/host/02-mount-chroot.sh [挂载点] [要拷入镜像的 payload 目录...]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"
require_root

MOUNT="${1:-/mnt/rootfs}"
shift || true
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

[[ -d "$MOUNT" ]] || die "挂载点不存在: $MOUNT"

mount --bind /dev      "$MOUNT/dev"
mount --bind /dev/pts  "$MOUNT/dev/pts"
mount -t proc  proc    "$MOUNT/proc"
mount -t sysfs sys     "$MOUNT/sys"
# 若镜像里的 /etc/resolv.conf 是软链（例如指向 systemd-resolved 的 stub），
# 直接 `cp -f` 会跟随软链写到不存在的目标目录并失败 —— 在 set -e 下会终止后续全部步骤。
# 因此先删再装。
rm -f "$MOUNT/etc/resolv.conf"
install -m644 /etc/resolv.conf "$MOUNT/etc/resolv.conf"

# 构建脚本入镜像（/root/vermeer-build）
install -d "$MOUNT/root/vermeer-build"
cp -a "$REPO_ROOT/scripts/common"    "$MOUNT/root/vermeer-build/"
cp -a "$REPO_ROOT/scripts/in-chroot" "$MOUNT/root/vermeer-build/"
cp -a "$REPO_ROOT/scripts/lists"     "$MOUNT/root/vermeer-build/"
chmod -R 755 "$MOUNT/root/vermeer-build"

# 设备包 .deb 入镜像 /tmp/debs
if [[ -d "$REPO_ROOT/debs" ]]; then
  install -d "$MOUNT/tmp/debs"
  cp -a "$REPO_ROOT/debs/." "$MOUNT/tmp/debs/"
  log "已拷入 $(find "$MOUNT/tmp/debs" -name '*.deb' | wc -l) 个 deb 到 /tmp/debs"
fi

# 其余 payload（boot.img / Image.gz-dtb_vermeer 等）
for extra in "$@"; do
  [[ -e "$extra" ]] || { warn "payload 不存在，跳过: $extra"; continue; }
  cp -a "$extra" "$MOUNT/root/vermeer-build/"
done

log "chroot 环境就绪: $MOUNT"
