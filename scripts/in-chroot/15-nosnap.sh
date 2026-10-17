#!/usr/bin/env bash
# 15-nosnap.sh —— 在镜像内彻底禁用 snap
#
# 这是本仓库相对上游 debian-sheng 之外的新增要求，三重保障：
#   1) apt pin：把 snapd / snap-confine 钉到负优先级，之后任何 apt 操作都不会引入；
#   2) 清除：如果镜像或某个依赖已经把 snapd 带进来，直接 purge 并 hold；
#   3) 校验：90-verify.sh 会在构建末尾硬校验 snapd 不存在，防止回归。
#
# 同时按 snap-free 原则选择桌面包（见 lists/*.list：不使用 ubuntu-desktop /
# kubuntu-desktop 等硬依赖 snapd 的元包；浏览器走 Mozilla apt 源，不用 firefox 过渡包）。
#
# 在 chroot 内执行:
#   chroot "$MOUNT" /root/vermeer-build/in-chroot/15-nosnap.sh
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/root/vermeer-build}"
# shellcheck source=/dev/null
source "$BUILD_DIR/common/distro-env.sh"
# shellcheck source=/dev/null
source "$BUILD_DIR/in-chroot/lib-apt.sh"

install -d /etc/apt/preferences.d

log "写入 apt pin（阻止 snapd 被任何来源拉入）"
# 为什么用 `Pin: version *` 而不是社区常见的 `Pin: release a=*`：
#   apt 的 release pin 匹配 Release 文件的字段，`a=` 对应 **Archive** 字段；
#   而 Ubuntu 的 Release 文件里只有 Suite/Codename（没有 Archive），因此
#   `release a=*` 在 Ubuntu 上**不匹配任何版本**，pin 形同虚设 —— 首次实跑时
#   10-base.sh 的断言就是这样抓到的。`version *` 无条件匹配所有版本，跨发行版都可靠。
cat > /etc/apt/preferences.d/nosnap.pref <<'EOF'
# ubuntu-vermeer：本系统不使用 snap，禁止安装 snapd 及其附属组件
Package: snapd
Pin: version *
Pin-Priority: -1

Package: snap-confine
Pin: version *
Pin-Priority: -1
EOF

# 防御性清除：基础 tarball 或某个依赖若已带入 snapd，这里移除
if dpkg-query -W -f='${Status}' snapd 2>/dev/null | grep -q "install ok installed"; then
  warn "检测到 snapd 已被安装，正在清除"
  apt-get purge -y snapd snap-confine 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
fi

# 注意：apt-mark hold 放在 10-base.sh 的 apt-get update 之后执行 ——
# 此时 apt 才认识 snapd 这个包名，否则会报 "Unable to locate package" 而被静默吞掉。
# 本脚本只负责写 pin 与清除已有 snapd。

# snap 相关目录（ubuntu-base 默认没有，这里兜底清理）
rm -rf /snap /var/lib/snapd /var/cache/snapd /root/snap 2>/dev/null || true

if command -v snap >/dev/null 2>&1; then
  die "snap 命令仍然存在，禁用 snap 失败"
fi

log "snap 已禁用（pin + 清除 + hold 完成）"
