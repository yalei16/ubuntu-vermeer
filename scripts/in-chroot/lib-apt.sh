#!/usr/bin/env bash
# chroot 内使用的通用工具：apt 封装 + 包列表读取
# 由 in-chroot/ 下各脚本 source。

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

APT_OPTS=(
  -y
  -o Dpkg::Options::=--force-confold
  -o Dpkg::Options::=--force-confdef
  -o Acquire::Retries=3
)

# chroot 构建前的 apt 环境准备：
#   * policy-rc.d：阻止各包 postinst 在 chroot 内启动服务（标准做法）。
#     必须在出厂前删除，否则设备上服务永远无法启动 —— 见 40-system-config.sh 与 90-verify.sh
#   * needrestart：Ubuntu 的 needrestart 在非交互环境下可能阻塞 apt 安装
prepare_apt() {
  # chroot 里的一切都依赖 apt-get：缺失时给出可读的错误，而不是后面一句
  # “apt-get: command not found”（引导阶段出问题时的典型症状）
  command -v apt-get >/dev/null 2>&1 \
    || die "chroot 内找不到 apt-get —— 引导阶段（ubuntu-base tarball / mmdebstrap）没有装出可用系统"
  if [[ ! -e /usr/sbin/policy-rc.d ]]; then
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
    chmod 755 /usr/sbin/policy-rc.d
    warn "已写入 policy-rc.d（将在系统配置阶段移除）"
  fi
  if [[ -d /etc/needrestart/conf.d ]]; then
    printf '$nrconf{restart} = "a";\n' > /etc/needrestart/conf.d/99-vermeer-noninteractive.conf
  fi
}

apt_update() { apt-get update; }

apt_install() {
  [[ "$#" -gt 0 ]] || return 0
  apt-get install "${APT_OPTS[@]}" "$@"
}

# 读取包列表文件：过滤注释与空行，输出空格分隔的一行
list_packages() {
  local file="$1" out
  [[ -f "$file" ]] || die "包列表不存在: $file"
  # grep 在"文件里全是注释/空行"时返回 1；若不做兜底，下面的赋值会在 set -e 下
  # 直接终止脚本，且没有任何可读的错误信息。
  out="$(grep -vE '^[[:space:]]*(#|$)' "$file" | tr '\n' ' ' || true)"
  [[ -n "${out// /}" ]] || die "包列表为空（只有注释或空行）: $file"
  printf '%s' "$out"
}

# 安装列表文件中的全部包
apt_install_list() {
  local file="$1" pkgs
  pkgs="$(list_packages "$file")"
  # shellcheck disable=SC2086
  apt_install $pkgs
}

# 尽力而为的安装（个别包名在某个版本上不存在时不至于让整个构建失败）
apt_install_best_effort() {
  [[ "$#" -gt 0 ]] || return 0
  apt_install "$@" || warn "可选包安装失败（已忽略）: $*"
}

# 尽力而为地安装一个包列表：整批安装失败时退回逐个安装并跳过缺失项。
# 动机：Ubuntu 各版本之间包名会改名/合并（t64 改名、KDE 6 包合并等），
# 一个可选包改名不该让整个构建失败；关键项改由 90-verify.sh 硬校验。
# 与 archlinux-sheng 的 pac_install_list_best_effort 对应。
apt_install_list_best_effort() {
  local file="$1" pkgs p
  pkgs="$(list_packages "$file")"
  # shellcheck disable=SC2086
  if apt_install $pkgs; then
    return 0
  fi
  warn "$(basename "$file"): 整批安装失败，改为逐个安装并跳过缺失项"
  for p in $pkgs; do
    apt_install "$p" || warn "跳过安装失败的包: $p"
  done
}
