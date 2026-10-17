#!/usr/bin/env bash
# 30-device-packages.sh —— 安装全部设备功能包（/tmp/debs/*.deb）并做设备侧收尾
#
# 相对 sheng 版本的改动：
#   * 必需包换成 vermeer 的：linux-xiaomi-vermeer / firmware-xiaomi-vermeer / fastrpc
#   * 删掉 sheng 的 sheng-sensors / sheng-devauth 服务启用（K70 没有对应物）
#   * 新增「modem 用户态」这一段：rmtfs / tqftpserv / qrtr-tools 是 SM8550 上
#     让 ADSP/MPSS 真正跑起来的前置条件（DSP 固件按需通过 TFTP 拉取）。
#     Ubuntu 归档里不一定都有这些包，因此是尽力而为 + 明确日志，不阻断构建。
#
# 在 chroot 内执行:
#   chroot "$MOUNT" /root/vermeer-build/in-chroot/30-device-packages.sh
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
INSTALL_MODEM_STACK="${INSTALL_MODEM_STACK:-true}"

shopt -s nullglob
debs=(/tmp/debs/*.deb)
[[ "${#debs[@]}" -gt 0 ]] || die "/tmp/debs 下没有 .deb"

log "待安装设备包（${#debs[@]} 个）："
for d in "${debs[@]}"; do
  printf '    %-42s %s\n' "$(basename "$d")" \
    "$(dpkg-deb -f "$d" Package 2>/dev/null) $(dpkg-deb -f "$d" Version 2>/dev/null)"
done

log "安装中"
if ! apt_install "${debs[@]}"; then
  warn "首次安装失败，尝试 apt-get install -f 修复依赖后重试"
  apt-get install -f -y || true
  apt_install "${debs[@]}" || die "设备包安装失败，请检查上面的依赖错误"
fi

# 版本断言：GNOME 桌面会把发行版的 iio-sensor-proxy 作为 Recommends 带进来。
# 发行版版没有 SSC 后端，传感器链路不工作 → 这里必须是我们构建的 9999x 版本。
IIO_VER="$(dpkg-query -W -f='${Version}' iio-sensor-proxy 2>/dev/null || true)"
case "$IIO_VER" in
  "")    warn "iio-sensor-proxy 未安装（本仓库的 deb 可能没装上）" ;;
  9999*) log "iio-sensor-proxy 使用本仓库版本: $IIO_VER" ;;
  *)     warn "iio-sensor-proxy 是发行版版本（$IIO_VER），不带 SSC 后端；K70 暂未提供传感器注册表，先不阻断" ;;
esac

# 权限修复：dpkg-deb 打包时统一 644，可执行文件需要显式补权限
log "修复可执行权限"
for f in /usr/bin/adsprpcd /usr/libexec/iio-sensor-proxy /usr/bin/monitor-sensor /usr/bin/ssccli; do
  if [[ -e "$f" ]]; then
    chmod +x "$f"
    printf '    +x %s\n' "$f"
  else
    printf '    (跳过，不存在) %s\n' "$f"
  fi
done

# depmod：让 /usr/lib/modules/<kver>/modules.dep 等索引在镜像内就生成
KVER="$(ls -1 /usr/lib/modules 2>/dev/null | head -n1 || true)"
if [[ -n "$KVER" ]]; then
  log "为内核 $KVER 生成模块依赖索引（depmod）"
  depmod -a "$KVER" || warn "depmod 返回非 0（可能已有现成索引）"
  [[ -f "/usr/lib/modules/$KVER/modules.dep" ]] \
    || die "modules.dep 未生成（$KVER）：模块在设备上无法自动加载"
else
  warn "未找到 /usr/lib/modules/*，内核包可能没有装上"
fi

# aDSP RPC 守护进程（传感器 / fastrpc 链路）
if [[ -f /usr/lib/systemd/system/adsprpcd-sensorspd.service ]]; then
  systemctl enable adsprpcd-sensorspd.service || warn "启用 adsprpcd-sensorspd 失败"
else
  warn "未找到 adsprpcd-sensorspd.service（fastrpc 包可能没装上）"
fi

# ── modem 用户态（4G 的前置条件，不是充分条件）──────────────────────────────
# 注意：K70 主线现在还没有把 &ipa 节点打开，所以即使这些服务跑起来，
# `mmcli -L` 依然可能看不到 modem。这里的目的是「把地基铺好」，
# 让后续在设备树上补 IPA/IPA SMMU 后不需要再改镜像。
if [[ "$INSTALL_MODEM_STACK" == "true" ]]; then
  log "安装 modem 用户态（rmtfs / tqftpserv / qrtr-tools，缺失则跳过）"
  apt_install_best_effort rmtfs tqftpserv qrtr-tools msm-firmware-loader
  for svc in rmtfs.service tqftpserv.service; do
    if [[ -f "/usr/lib/systemd/system/$svc" || -f "/lib/systemd/system/$svc" ]]; then
      systemctl enable "$svc" || warn "启用 $svc 失败"
      log "已启用 $svc"
    else
      warn "缺少 $svc（对应包没装上，实际设备上 DSP 固件可能拉不起来）"
    fi
  done
else
  log "INSTALL_MODEM_STACK=false，跳过 modem 用户态"
fi

log "设备包安装完成"
