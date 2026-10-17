#!/usr/bin/env bash
# 10-base.sh —— 在 chroot 内安装基础系统包（Ubuntu）
#
# 对应上游 debian-sheng “Install Base Packages” 步骤。
# 在 chroot 内执行：
#   chroot "$MOUNT" /root/vermeer-build/in-chroot/10-base.sh
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/root/vermeer-build}"
# shellcheck source=/dev/null
source "$BUILD_DIR/common/distro-env.sh"
# shellcheck source=/dev/null
source "$BUILD_DIR/in-chroot/lib-apt.sh"

prepare_apt

log "安装基础包（$DISTRO_SERIES / $DISTRO_SUITE）"
apt_update

# snap 禁用必须在任何安装前生效，并且要**当场断言**：一旦 pin 没生效，
# snapd 会经 Recommends 链被拉进来，直到最后一步 90-verify.sh 才失败 —— 白烧一小时构建。
# 断言方式：用 `apt-get install -s`（模拟，不下载）判断 apt 是否认为 snapd 可安装。
#   ⚠️ 不要用解析 apt-cache policy 文本的方式：实跑发现 pin 生效时的表现是
#      `Candidate: (none)`，输出里并没有字面 "Pin-Priority:" 字样（前两次误判都源于此）。
if apt-get install -s -y snapd >/dev/null 2>&1; then
  warn "nosnap.pref 似乎未生效，以下是 apt-cache policy snapd 的原始输出："
  apt-cache policy snapd 2>&1 | sed 's/^/    /' || true
  die "nosnap.pref 未生效：apt 模拟安装 snapd 成功（pin 写法见 15-nosnap.sh 的注释）"
fi
apt-mark hold snapd 2>/dev/null || warn "apt-mark hold snapd 失败（pin 仍然有效，不致命）"
log "已确认 apt 无法安装 snapd（nosnap pin 生效），并尝试 hold"

apt_install_list "$BUILD_DIR/lists/base.list"

# 上游显式预装的运行期库（best-effort，带 t64 兜底），见 lists/runtime-libs.list 的说明
apt_install_list_best_effort "$BUILD_DIR/lists/runtime-libs.list"

# wireless-regdb 的 alternatives（与上游 “Use Upstream Regulatory Database” 步骤一致）
if [[ -x /usr/bin/update-alternatives && -e /lib/firmware/regulatory.db-upstream ]]; then
  update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream \
    || warn "设置 regulatory.db alternatives 失败"
  log "已切换到 upstream 无线管制数据库"
else
  log "跳过 regulatory.db alternatives（该版本未提供）"
fi

log "基础包安装完成"
