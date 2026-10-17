#!/usr/bin/env bash
# 设备常量：红米 K70 / POCO F6 Pro（vermeer，高通 SM8550）
#
# 这个文件是整仓库**唯一**存放设备名字与上游地址的地方：
# 换机型（例如回到 sheng、或移植到同 SoC 的 manet）只需要改这里的取值，
# 其余脚本/workflow 一律只引用变量，不再出现硬编码的机型字符串。
#
# 被 host/ 与 in-chroot/ 下的脚本共同 source（放在 distro-env.sh 之后）。

# ── 机型 ────────────────────────────────────────────────────────────────────
export DEVICE_SLUG="${DEVICE_SLUG:-vermeer}"
export DEVICE_SOC="${DEVICE_SOC:-sm8550}"
export DEVICE_PRETTY_NAME="${DEVICE_PRETTY_NAME:-Xiaomi Redmi K70 / POCO F6 Pro}"
# 设备树里的 model 字符串（DT 匹配 libdeviceinfo 用）
export DEVICE_DT_MODEL="${DEVICE_DT_MODEL:-Poco F6 Pro}"

# ── 内核 ────────────────────────────────────────────────────────────────────
# vermeer 的设备树与面板驱动都只在 XEC 这棵树里（torvalds 主线没有 vermeer）
export DEFAULT_KERNEL_REPO="${DEFAULT_KERNEL_REPO:-https://github.com/Xlie-Electronic-Customs/linux}"
export DEFAULT_KERNEL_BRANCH="${DEFAULT_KERNEL_BRANCH:-master}"
export DEVICE_DTB="${DEVICE_DTB:-sm8550-xiaomi-vermeer.dtb}"
# 拼接好的内核镜像（Image.gz + DTB），mkbootimg 的 --kernel 输入
export DEVICE_KERNEL_IMAGE="${DEVICE_KERNEL_IMAGE:-Image.gz-dtb_vermeer}"
# 内核配置片段：相对内核树 arch/arm64/configs/，按顺序叠加在 defconfig 之上
export KERNEL_CONFIG_FRAGMENTS="${KERNEL_CONFIG_FRAGMENTS:-sm8550.config hardening.config}"
# 本仓库自己的额外片段（相对仓库根），最后叠加，用于把 =m 的 modem/IPA 链路提为 =y
export KERNEL_EXTRA_CONFIG="${KERNEL_EXTRA_CONFIG:-vermeer-extra.config}"

# ── 设备包名 ────────────────────────────────────────────────────────────────
export KERNEL_DEB="${KERNEL_DEB:-linux-xiaomi-vermeer}"
export FIRMWARE_DEB="${FIRMWARE_DEB:-firmware-xiaomi-vermeer}"

# ── 固件 ────────────────────────────────────────────────────────────────────
export DEFAULT_FIRMWARE_REPO="${DEFAULT_FIRMWARE_REPO:-https://github.com/Xlie-Electronic-Customs/linux-firmware-xiaomi-vermeer}"
export DEFAULT_FIRMWARE_BRANCH="${DEFAULT_FIRMWARE_BRANCH:-main}"
# 上游固件仓库把固件放在这个子目录下（xec: xiaomi-vermeer/{ath12k,qcom}）
# 打包时把**子目录内容**铺到 /usr/lib/firmware/，空值表示仓库根就是固件根
export FIRMWARE_SUBDIR="${FIRMWARE_SUBDIR:-xiaomi-vermeer}"

# ── rootfs 内构建目录（脚本在这里被 chroot 执行）─────────────────────────────
export BUILD_DIR_NAME="${BUILD_DIR_NAME:-vermeer-build}"
