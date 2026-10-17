#!/usr/bin/env bash
# 25-browser.sh —— 可选：安装 snap-free 的 Firefox（Mozilla 官方 apt 源）
#
# 背景：Ubuntu 主归档里的 firefox / chromium-browser 都是 snap 过渡包，
# 在没有 snapd 的系统上装不了。因此浏览器改为从 Mozilla 官方 apt 仓库安装
# deb 版 firefox，并给该源高优先级，避免 apt 又去选 Ubuntu 的过渡包。
#
# 环境变量：
#   BROWSER  none（默认） / firefox
#
# 在 chroot 内执行:
#   chroot "$MOUNT" /root/vermeer-build/in-chroot/25-browser.sh
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/root/vermeer-build}"
# shellcheck source=/dev/null
source "$BUILD_DIR/common/distro-env.sh"
# shellcheck source=/dev/null
source "$BUILD_DIR/in-chroot/lib-apt.sh"

BROWSER="${BROWSER:-none}"

case "$BROWSER" in
  none|"")
    log "BROWSER=none：不安装浏览器（Ubuntu 的 firefox 是 snap 过渡包）"
    exit 0
    ;;
  firefox) ;;
  *) die "未知的 BROWSER: $BROWSER（可选 none / firefox）" ;;
esac

log "配置 Mozilla 官方 apt 源（提供 deb 版 firefox）"
install -d /etc/apt/keyrings
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
     -o /etc/apt/keyrings/packages.mozilla.org.asc
chmod 644 /etc/apt/keyrings/packages.mozilla.org.asc

cat > /etc/apt/sources.list.d/mozilla.sources <<'EOF'
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF

cat > /etc/apt/preferences.d/mozilla.pref <<'EOF'
# 优先使用 Mozilla 官方源，避免装到 Ubuntu 的 snap 过渡包
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

apt_update
apt_install firefox

log "Firefox（deb 版）安装完成: $(dpkg-query -W -f='${Version}' firefox 2>/dev/null || echo '未知版本')"
