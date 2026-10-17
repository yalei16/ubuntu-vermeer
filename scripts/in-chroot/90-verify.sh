#!/usr/bin/env bash
# 90-verify.sh —— 构建末尾的硬校验
#
# 除了上游没有的 snap 校验，还检查若干"装错了也能出镜像"的关键项：
#   * snapd 必须不存在（本仓库的硬性要求）
#   * 内核模块索引 modules.dep 必须存在（上游缺 depmod）
#   * fstab 必须按 PARTLABEL + x-systemd.growfs 写好
#   * 设备功能包的关键二进制/服务是否就位
#   * policy-rc.d 必须已移除（否则设备上服务永远起不来）
#
# 在 chroot 内执行:
#   chroot "$MOUNT" /root/vermeer-build/in-chroot/90-verify.sh
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-/root/vermeer-build}"
# shellcheck source=/dev/null
source "$BUILD_DIR/common/distro-env.sh"
# shellcheck source=/dev/null
source "$BUILD_DIR/common/device-env.sh"
# shellcheck source=/dev/null
source "$BUILD_DIR/in-chroot/lib-apt.sh"

if [[ -f /root/build.env ]]; then
  # shellcheck source=/dev/null
  source /root/build.env
fi

FAIL=0
pass() { printf '  [ OK ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }
skip() { printf '  [SKIP] %s\n' "$*"; }

log "开始校验"

# 1) snap
if dpkg-query -W -f='${Status}' snapd 2>/dev/null | grep -q "install ok installed"; then
  fail "snapd 已安装（本仓库要求完全禁用 snap）"
else
  pass "snapd 未安装"
fi
if [[ -e /snap || -e /var/lib/snapd ]]; then
  fail "存在 snap 目录（/snap 或 /var/lib/snapd）"
else
  pass "无 snap 目录"
fi
if command -v snap >/dev/null 2>&1; then
  fail "snap 命令存在"
else
  pass "snap 命令不存在"
fi
[[ -f /etc/apt/preferences.d/nosnap.pref ]] && pass "nosnap.pref 已写入" || fail "nosnap.pref 缺失"

# 2) 内核模块
KVER="$(ls -1 /usr/lib/modules 2>/dev/null | head -n1 || true)"
if [[ -n "$KVER" && -f "/usr/lib/modules/$KVER/modules.dep" ]]; then
  pass "内核模块就绪: $KVER（modules.dep 已生成）"
else
  fail "内核模块不完整（KVER=${KVER:-无}，缺少 modules.dep）"
fi

# 3) fstab
if grep -qE "^PARTLABEL=.*[[:space:]]/[[:space:]]+ext4.*x-systemd\.growfs" /etc/fstab 2>/dev/null; then
  pass "fstab 正确（PARTLABEL + x-systemd.growfs）"
else
  fail "fstab 不符合预期: $(tr '\n' ' ' < /etc/fstab 2>/dev/null)"
fi

# 4) 设备功能包关键文件
#    firmware-xiaomi-vermeer 装的是 WCN7850（ath12k）与 GPU/DSP 固件，
#    缺了它们不会影响开机，但 WiFi 一定不工作 —— 所以按硬校验处理。
for f in /usr/bin/adsprpcd \
         /usr/lib/firmware/ath12k/WCN7850 \
         /usr/lib/firmware/qcom/sm8550/xiaomi/vermeer; do
  if [[ -e "$f" ]]; then
    pass "存在 $f"
  else
    fail "缺少 $f"
  fi
done

# 5) 用户 / 自动登录 / locale
if id "${USERNAME:-}" >/dev/null 2>&1; then
  pass "用户存在: $USERNAME"
else
  fail "用户不存在: ${USERNAME:-<未设置>}"
fi

if [[ "${AUTOLOGIN:-false}" == "true" ]]; then
  case "${DESKTOP:-server}" in
    GNOME)
      # Ubuntu 的 GDM 读 /etc/gdm3/custom.conf（不是 Debian 的 daemon.conf）
      if grep -qE '^AutomaticLoginEnable[[:space:]]*=[[:space:]]*true' /etc/gdm3/custom.conf 2>/dev/null \
         && grep -qE '^AutomaticLogin=' /etc/gdm3/custom.conf 2>/dev/null; then
        pass "GDM 自动登录已配置（/etc/gdm3/custom.conf）"
      else
        fail "GDM 自动登录未生效（检查 /etc/gdm3/custom.conf）"
      fi
      ;;
    "KDE Plasma")
      if [[ -f /etc/sddm.conf.d/autologin.conf ]]; then
        pass "SDDM 自动登录已配置"
      else
        fail "缺少 /etc/sddm.conf.d/autologin.conf"
      fi
      ;;
  esac
fi

# 4b) Lomiri 会话链路（缺任何一环，真机上就停在 tty1 的登录提示）
if [[ "${DESKTOP:-server}" == "Lomiri" ]]; then
  for f in /usr/bin/lomiri /usr/bin/lomiri-session \
           /usr/share/wayland-sessions/lomiri.desktop \
           /usr/lib/systemd/user/lomiri.service; do
    [[ -e "$f" ]] && pass "存在 $f" || fail "缺少 $f"
  done
  if [[ -f /etc/greetd/config.toml ]] \
     && grep -q 'lomiri-session' /etc/greetd/config.toml; then
    pass "greetd 指向 lomiri-session"
  else
    fail "greetd 未指向 lomiri-session（检查 /etc/greetd/config.toml）"
  fi
  # getty 与 greetd 抢 tty1：没 mask 掉 Lomiri 就起不来
  if [[ "$(readlink -f /etc/systemd/system/getty@tty1.service 2>/dev/null)" == "/dev/null" ]]; then
    pass "getty@tty1 已 mask（greetd 独占 vt1）"
  else
    fail "getty@tty1 未 mask，会和 greetd 抢 tty1"
  fi
fi

# 4c) 设备形态与显示缩放（Lomiri UI 尺寸正确的前提）
if [[ -f "/etc/deviceinfo/devices/${DEVICE_SLUG}.yaml" ]]; then
  pass "deviceinfo 设备描述已写入"
  if grep -qE '^[[:space:]]*GridUnit:[[:space:]]*18' "/etc/deviceinfo/devices/${DEVICE_SLUG}.yaml"; then
    pass "GridUnit = 18（446 PPI 手机）"
  else
    fail "GridUnit 不是 18，Lomiri UI 会明显偏小"
  fi
else
  fail "缺少 /etc/deviceinfo/devices/${DEVICE_SLUG}.yaml"
fi
if grep -qE '^[[:space:]]*CHASSIS=handset' /etc/machine-info 2>/dev/null; then
  pass "CHASSIS=handset"
else
  fail "/etc/machine-info 未设 CHASSIS=handset"
fi
if [[ "${DESKTOP:-server}" == "Lomiri" ]]; then
  if grep -qE '^DEFAULT_GRID_UNIT_PX=18' /etc/default/lomiri-desktop-session 2>/dev/null; then
    pass "lomiri 会话缩放覆盖已写入"
  else
    fail "缺少 /etc/default/lomiri-desktop-session 的 DEFAULT_GRID_UNIT_PX=18"
  fi
fi

# 传感器守护进程不仅要存在，还必须真的被 enable（否则传感器链路不工作）
if [[ -f /usr/lib/systemd/system/adsprpcd-sensorspd.service ]]; then
  if systemctl is-enabled adsprpcd-sensorspd.service >/dev/null 2>&1 \
     || [[ -e /etc/systemd/system/iio-sensor-proxy.service.wants/adsprpcd-sensorspd.service ]] \
     || [[ -e /etc/systemd/system/multi-user.target.wants/adsprpcd-sensorspd.service ]]; then
    pass "adsprpcd-sensorspd.service 已启用"
  else
    fail "adsprpcd-sensorspd.service 存在但未启用（传感器不会工作）"
  fi
fi

# 显示管理器与网络必须真的 enabled（否则装好桌面也不会进图形界面/没有网络）
if [[ "${DESKTOP:-server}" != "server" ]]; then
  dm=""
  case "${DESKTOP:-}" in
    GNOME)       dm="gdm3" ;;
    "KDE Plasma") dm="sddm" ;;
    Lomiri)      dm="greetd" ;;
  esac
  if [[ -n "$dm" ]]; then
    if [[ -e /etc/systemd/system/display-manager.service ]] \
       || systemctl is-enabled "$dm.service" >/dev/null 2>&1 \
       || [[ -e "/etc/systemd/system/graphical.target.wants/$dm.service" ]]; then
      pass "$dm.service 已启用"
    else
      fail "$dm.service 未启用"
    fi
  fi
fi

if [[ -e /etc/systemd/system/multi-user.target.wants/NetworkManager.service ]] \
   || systemctl is-enabled NetworkManager.service >/dev/null 2>&1; then
  pass "NetworkManager 已启用"
else
  fail "NetworkManager 未启用"
fi

if [[ "${LANGUAGE:-None (C.UTF-8)}" != "None (C.UTF-8)" ]]; then
  grep -q "${LANGUAGE}" /etc/default/locale 2>/dev/null && pass "locale 已写入: $LANGUAGE" || fail "locale 未写入"
fi

# 6) policy-rc.d 必须已移除
if [[ -e /usr/sbin/policy-rc.d ]]; then
  fail "policy-rc.d 仍存在（会导致设备上服务无法启动）"
else
  pass "policy-rc.d 已移除"
fi

if [[ "$FAIL" -ne 0 ]]; then
  die "校验未通过，镜像不可用"
fi
log "全部校验通过"
