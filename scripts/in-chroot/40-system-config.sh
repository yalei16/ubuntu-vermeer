#!/usr/bin/env bash
# 40-system-config.sh —— 系统级配置：主机名 / locale / 用户 / 密码 / 显示管理器 /
# 自动登录 / 网络 / fstab
#
# 对应上游 debian-sheng 的 Set Hostname、Configure Locale、Create User、Set Passwords、
# Configure GDM/SDDM(+Autologin)、Enable NetworkManager、Configure fstab、Clean APT Cache。
# 另加：Lomiri 的 greetd 会话配置，以及 libdeviceinfo 的设备形态 / 显示缩放。
#
# 环境变量：
#   /root/build.env 提供 HOSTNAME / USERNAME / LANGUAGE / AUTOLOGIN / DESKTOP /
#                    PLASMA_MOBILE / PARTITION_LABEL / QUIET_BOOT
#   ROOTFS_PASSWORD 由 workflow 通过 env 传入（不落盘；为空则回退到上游的 password）
#
# 在 chroot 内执行:
#   chroot "$MOUNT" env ROOTFS_PASSWORD=... /root/vermeer-build/in-chroot/40-system-config.sh
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

: "${HOSTNAME:?需要 HOSTNAME}"
: "${USERNAME:?需要 USERNAME}"
DESKTOP="${DESKTOP:-server}"
AUTOLOGIN="${AUTOLOGIN:-false}"
PLASMA_MOBILE="${PLASMA_MOBILE:-false}"
LANGUAGE="${LANGUAGE:-None (C.UTF-8)}"
PARTITION_LABEL="${PARTITION_LABEL:-linux}"

# ---------------------------------------------------------------------------
# 1) 主机名
# ---------------------------------------------------------------------------
log "设置主机名: $HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
if ! grep -q "127.0.1.1[[:space:]]*$HOSTNAME" /etc/hosts 2>/dev/null; then
  echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
fi

# ---------------------------------------------------------------------------
# 2) locale（与上游一致：生成所选 locale + en_US.UTF-8，写 /etc/default/locale）
# ---------------------------------------------------------------------------
if [[ "$LANGUAGE" == "None (C.UTF-8)" ]]; then
  log "locale: 保持 C.UTF-8（跳过 locale-gen）"
else
  log "生成 locale: $LANGUAGE"
  apt_install locales
  sed -i 's/^# *\(en_US\.UTF-8\)/\1/' /etc/locale.gen
  esc="$(printf '%s' "$LANGUAGE" | sed 's/\./\\./g')"
  sed -i "s/^# *\(${esc}\)/\1/" /etc/locale.gen
  locale-gen
  # 生成结果校验：locale -a 的命名与 locale.gen 的写法不完全一致（zh_CN.UTF-8 → zh_CN.utf8），
  # 因此只做归一化后的比对并告警，不硬失败
  _want="$(printf '%s' "$LANGUAGE" | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/')"
  if ! locale -a 2>/dev/null | tr 'A-Z' 'a-z' | grep -qx "$_want"; then
    warn "locale -a 里没有找到 $_want（可能是命名差异），请人工确认 locale 是否生效"
  else
    log "locale 已生成: $_want"
  fi
  echo "LANG=$LANGUAGE" > /etc/default/locale   # Debian/Ubuntu 约定
  echo "LANG=$LANGUAGE" > /etc/locale.conf      # systemd 直接读取，双写更稳
fi

# ---------------------------------------------------------------------------
# 3) 用户与密码（上游语义：用户与 root 同密码）
# ---------------------------------------------------------------------------
if ! id "$USERNAME" >/dev/null 2>&1; then
  log "创建用户: $USERNAME（加入 sudo 组）"
  useradd -m -s /bin/bash -G sudo "$USERNAME"
fi

# 密码由 workflow 写入 /root/build.pw（600），读完即删，避免出现在命令行参数里
if [[ -z "${ROOTFS_PASSWORD:-}" && -f /root/build.pw ]]; then
  ROOTFS_PASSWORD="$(cat /root/build.pw)"
fi
if [[ -z "${ROOTFS_PASSWORD:-}" ]]; then
  warn "ROOTFS_PASSWORD 未设置，使用上游同样的默认密码: password"
  ROOTFS_PASSWORD="password"
fi
printf '%s:%s\n' "$USERNAME" "$ROOTFS_PASSWORD" | chpasswd
printf 'root:%s\n' "$ROOTFS_PASSWORD" | chpasswd
rm -f /root/build.pw
log "已设置 $USERNAME 与 root 的密码"

# ---------------------------------------------------------------------------
# 4) 网络
# ---------------------------------------------------------------------------
log "启用 NetworkManager"
systemctl enable NetworkManager.service || warn "启用 NetworkManager 失败"

# ---------------------------------------------------------------------------
# 5) 显示管理器 + 自动登录
# ---------------------------------------------------------------------------
case "$DESKTOP" in
  GNOME)
    if [[ "$AUTOLOGIN" == "true" ]]; then
      log "配置 GDM 自动登录: $USERNAME"
      # 路径很重要：Ubuntu 的 gdm3 只读 **/etc/gdm3/custom.conf**；上游 Debian 用的
      # /etc/gdm3/daemon.conf 在 Ubuntu 上是惰性文件（直接照搬会静默失效，登录界面照旧）。
      install -d /etc/gdm3
      if [[ -f /etc/gdm3/custom.conf ]]; then
        sed -i -E 's/^#[[:space:]]*AutomaticLoginEnable[[:space:]]*=.*/AutomaticLoginEnable=true/' /etc/gdm3/custom.conf
        sed -i -E "s/^#[[:space:]]*AutomaticLogin[[:space:]]*=.*/AutomaticLogin=${USERNAME}/" /etc/gdm3/custom.conf
      fi
      # 上面两条 sed 只有在文件里存在被注释掉的同名键时才生效；否则重写为最小 [daemon] 段
      if ! { grep -qE '^AutomaticLoginEnable' /etc/gdm3/custom.conf && grep -qE '^AutomaticLogin=' /etc/gdm3/custom.conf; }; then
        warn "custom.conf 结构不符合预期（缺少已注释的 AutomaticLogin* 键），重写为最小 [daemon] 段"
        printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$USERNAME" > /etc/gdm3/custom.conf
      fi
      # Debian 系兼容：Ubuntu 不读该文件，写出无害
      printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$USERNAME" > /etc/gdm3/daemon.conf
    fi
    systemctl enable gdm3.service || warn "启用 gdm3 失败"
    systemctl set-default graphical.target
    ;;
  "KDE Plasma")
    if [[ "$AUTOLOGIN" == "true" ]]; then
      if [[ "$PLASMA_MOBILE" == "true" ]]; then SDDM_SESSION="plasma-mobile"; else SDDM_SESSION="plasma"; fi
      log "配置 SDDM 自动登录: $USERNAME (session=$SDDM_SESSION)"
      install -d /etc/sddm.conf.d
      cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=$USERNAME
Session=$SDDM_SESSION
EOF
    fi
    systemctl enable sddm.service || warn "启用 sddm 失败"
    systemctl set-default graphical.target
    ;;
  Lomiri)
    # greetd 的 config.toml 里 [default_session] 的 command 就是会话命令本身，
    # 把它设成 lomiri-session 等价于自动登录（会话退出后 greetd 会重启它）。
    # 镜像里不放 greeter：lomiri-greeter 那个包是 LightDM 用的，对 greetd 无效。
    if [[ "$AUTOLOGIN" != "true" ]]; then
      warn "Lomiri 经 greetd 恒为自动登录（[default_session] 即会话命令），autologin=false 已忽略"
    fi
    log "配置 greetd 启动 Lomiri 会话: $USERNAME"
    install -d /etc/greetd
    cat > /etc/greetd/config.toml <<EOF
[terminal]
vt = 1

[default_session]
command = "/usr/bin/lomiri-session"
user = "$USERNAME"
EOF
    # getty 默认占住 tty1，会和 greetd 的 vt = 1 抢同一个终端。真机上的表现是
    # 屏幕上停着 tty1 的登录提示、Lomiri 永远起不来，所以必须 mask 掉。
    systemctl mask getty@tty1.service || warn "mask getty@tty1 失败"
    systemctl enable greetd.service || warn "启用 greetd 失败"
    systemctl set-default graphical.target
    ;;
  server)
    log "server 模式：不配置显示管理器"
    ;;
esac

# ---------------------------------------------------------------------------
# 5b) 设备形态与显示缩放（libdeviceinfo）
# ---------------------------------------------------------------------------
# lomiri-session 的 GRID_UNIT_PX 取自 `device-info get GridUnit`，
# 不配置时兜底是 desktop 档（GridUnit 8），在手机上整套 UI 会小到没法点。
#
# K70 = 6.67" 1220x2712 ≈ 446 PPI 的手持机：按 UBports 参考表（423 PPI 的
# Nexus 5X 用 18）取 18。
#
# 匹配方式：拿 /proc/device-tree/model 去比 yaml 里的 Names，
# vermeer 的 DT model 是 “Poco F6 Pro”（这棵树里同时保留了 K70 的别名）。
log "写入设备形态与显示参数（libdeviceinfo）"
install -d /etc/deviceinfo/devices
cat > /etc/deviceinfo/devices/"$DEVICE_SLUG".yaml <<'EOF'
vermeer:
  Names:
    - "Poco F6 Pro"
    - "Xiaomi Redmi K70"
    - "xiaomi,vermeer"
    - "Xiaomi-K70"
    - "vermeer"
  PrettyName: "Xiaomi Redmi K70 / POCO F6 Pro"
  DeviceType: phone
  GridUnit: 18
  WebkitDpr: 3
  SupportedOrientations:
    - Portrait
    - InvertedPortrait
    - Landscape
    - InvertedLandscape
  PrimaryOrientation: Portrait
EOF
# FORM_FACTOR 取的是 chassis，hostnamectl 读 /etc/machine-info
printf 'CHASSIS=handset\n' > /etc/machine-info

if [[ "$DESKTOP" == "Lomiri" ]]; then
  # lomiri-session 开头就 source 这个文件，DEFAULT_GRID_UNIT_PX 会直接短路掉
  # device-info 探测（脚本里是 ${DEFAULT_GRID_UNIT_PX:-$(device-info ...)}）。
  # 这是保底：即便上面那份 yaml 因 DT model 改名而匹配不上，缩放依然正确。
  log "写入 Lomiri 会话缩放覆盖 GRID_UNIT_PX=18"
  cat > /etc/default/lomiri-desktop-session <<'EOF'
# 由 /usr/bin/lomiri-session 开头 source；DEFAULT_* 优先级高于 device-info 探测。
DEFAULT_GRID_UNIT_PX=18
DEFAULT_NATIVE_ORIENTATION=Portrait
EOF
fi

# ---------------------------------------------------------------------------
# 6) fstab（PARTLABEL 定位根分区；x-systemd.growfs 首启自动扩容）
# ---------------------------------------------------------------------------
log "写入 fstab: PARTLABEL=$PARTITION_LABEL"
cat > /etc/fstab <<EOF
# <file system>            <mount point>  <type>  <options>                          <dump> <pass>
PARTLABEL=$PARTITION_LABEL /              ext4    defaults,x-systemd.growfs         0      1
EOF

# ---------------------------------------------------------------------------
# 7) machine-id：清空为空文件，让设备首启由 systemd 生成唯一 ID
#    （若在构建期就生成了 ID，所有同版本镜像会共用同一个 machine-id）
# ---------------------------------------------------------------------------
: > /etc/machine-id

# ---------------------------------------------------------------------------
# 8) 清理
# ---------------------------------------------------------------------------
log "清理 apt 缓存"
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* 2>/dev/null || true

# chroot 内的 policy-rc.d 只用于阻止 postinst 启服务，出厂前必须移除
rm -f /usr/sbin/policy-rc.d

log "系统配置完成"
