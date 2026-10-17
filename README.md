# ubuntu-vermeer

[![Validate](https://github.com/yalei16/ubuntu-vermeer/actions/workflows/validate.yml/badge.svg?branch=main)](https://github.com/yalei16/ubuntu-vermeer/actions/workflows/validate.yml)
[![Build RootFS](https://github.com/yalei16/ubuntu-vermeer/actions/workflows/rootfs.yml/badge.svg?branch=main)](https://github.com/yalei16/ubuntu-vermeer/actions/workflows/rootfs.yml)

用 **GitHub Actions** 为 **红米 K70 / POCO F6 Pro（vermeer / 高通 SM8550）** 构建 **Ubuntu arm64**
的 `rootfs.img` 与 `boot.img`，产物可直接用 `fastboot` 刷入设备。

本项目是 [code002-2/ubuntu-sheng](https://github.com/code002-2/ubuntu-sheng)（小米平板 6S Pro）
的移植版本：构建流水线、rootfs 组装、分区与刷写思路完全复用，替换掉的是**内核来源、
固件包、设备包、boot.img 头参数、设备形态**这几处设备相关的东西。
逐项对照见 [docs/移植对照.md](docs/移植对照.md)，装机步骤见 [docs/安装指南.md](docs/安装指南.md)。

> 前置条件：K70 已解锁 BootLoader（国行门槛很高），并且有可用的 TWRP。
> 主线内核**不会**动 Android 分区；但任何刷写都有风险，请先按《安装指南》备份原厂 boot。

## 上游依赖

| 内容 | 上游 | 说明 |
|---|---|---|
| 内核（含 vermeer DTS、K70 面板驱动） | [Xlie-Electronic-Customs/linux](https://github.com/Xlie-Electronic-Customs/linux) `master` | 主线 7.3.0，**vermeer 的设备树只在这棵树里**（torvalds 主线没有） |
| 设备固件 | [Xlie-Electronic-Customs/linux-firmware-xiaomi-vermeer](https://github.com/Xlie-Electronic-Customs/linux-firmware-xiaomi-vermeer) `main` | 固件在仓库的 `xiaomi-vermeer/` 子目录下（WCN7850 / A740 / Goodix 等） |
| fastrpc / libssc / iio-sensor-proxy | 各自上游 | 与 sheng 项目同一套源码构建 |

## 参数说明

| 参数 | 默认值 | 说明 |
|---|---|---|
| **Ubuntu 版本** | `26.04 (resolute)` | 可选 `26.10 (stonking)`（开发中）与 `25.10 (questing)`；apt 源按版本自动选择 |
| **桌面环境** | `KDE Plasma` | `GNOME` / `Lomiri` / `server`。手机屏上 plasma-mobile 或 Lomiri 体验更合适 |
| **plasma_mobile** | `false` | 勾选后用 `plasma-mobile` 替代 `plasma-desktop`（仅 KDE Plasma 生效） |
| **browser** | `none` | `firefox` = 从 Mozilla 官方 apt 源安装 deb 版（Ubuntu 归档的 firefox 是 snap 过渡包） |
| **autologin** | `true` | 自动登录（GNOME → `/etc/gdm3/custom.conf`；KDE → `/etc/sddm.conf.d/autologin.conf`；Lomiri 恒为自动登录） |
| **username / hostname** | `username` / `xiaomi-vermeer` | 仅允许字母数字与 `_ . -` |
| **password** | *(空)* | 普通用户与 `root` 同密码。留空则用 Secret `ROOTFS_PASSWORD`，都为空时为 `password` |
| **language** | `zh_CN.UTF-8` | 选择后生成该 locale + `en_US.UTF-8` |
| **boot_mode** | `dual (linux)` | `single (userdata)` / `dual (linux)` / `custom`；决定 fstab 的 `PARTLABEL=` |
| **custom_partition** | *(空)* | 仅 `boot_mode=custom` 需要 |
| **quiet_boot** | `true` | Plymouth 安静启动（`server` 模式忽略） |
| **kernel_source** | `custom_build` | **vermeer 没有现成的 boot.img release**，默认自己编（约 40–60 分钟）。`prebuilt` 仅在你自己发布过 boot.img 时才用 |
| **kernel_repo / kernel_branch** | `Xlie-Electronic-Customs/linux` / `master` | 只在这棵树里有 `sm8550-xiaomi-vermeer.dts` 与 `panel-n11-42-02-0a-dsc.c` |
| **kernel_config_fragments** | `sm8550.config hardening.config` | 叠加在 `defconfig` 之上的树内片段（该树没有 vermeer_defconfig） |
| **kernel_releases_repo / kernel_boot_pattern** | *(空)* | 仅 `kernel_source=prebuilt` 时需要 |
| **firmware_repo / firmware_branch** | XEC 固件仓库 / `main` | 固件在 `xiaomi-vermeer/` 子目录 |
| **boot_header_version** | `4` | K70 原厂 boot.img 是 GKI header v4。**务必用 `12-analyze-bootimg.py` 对原厂镜像核对**；sheng 是 v0，照抄会 `invalid boot image` |
| **boot_pagesize** | `4096` | 同上，以实测为准 |
| **append_dtb** | `true` | 把 DTB 拼到内核尾部（pmOS 的 append_dtb）。原厂 boot.img 的内核尾部并没有 DTB（ABL 从 vendor_boot/dtbo 取），若实测发现 ABL 忽略追加的 DT，改成 `false` —— 详见 docs/移植对照.md §6 |
| **extra_cmdline** | *(空)* | 追加内核 cmdline，例如 `earlycon console=ttyMSM0,115200` |
| **install_modem_stack** | `true` | 尽力安装 rmtfs / tqftpserv / qrtr-tools（4G 的前置条件，见下） |
| **rootfs_size** | `10G` | 镜像初始大小；构建后收缩，首启由 `x-systemd.growfs` 扩到分区实际大小 |
| **shrink_image** | `true` | 构建后 `e2fsck -fy` + `resize2fs -M` 收缩镜像 |
| **upload_artifacts** | `true` | 设为 `false` 只验证流程、不产出 Artifact |

## 产物

- `rootfs.img` —— ext4 文件系统镜像（**无分区表**），直接刷到一个分区
- `boot.img` —— header v4（GKI，与原厂实测一致：pagesize 4096 / ramdisk 0），
  内核是**未压缩** `Image` + `sm8550-xiaomi-vermeer.dtb` 拼接（可用 `append_dtb` 关掉），
  cmdline 为 `root=PARTLABEL=<分区>`；**不带 initramfs**（UFS/显示/触摸驱动都是 built-in）
- `linux-xiaomi-vermeer.deb` —— 内核 + 模块 + `/boot/dtb-<ver>.dtb`（做 vendor_boot 要用）
- Actions 里同时保留 `firmware-xiaomi-vermeer.deb`、`kernel-dtb_vermeer` 等中间产物

> **必须额外刷 vendor_boot**：实测 K70 原厂 `boot.img` 的内核区间里没有 DTB，
> 设备树在 `vendor_boot.img` 里（dtb_size 3885971 / dtb_addr 0x1f00000）。
> 只刷 boot.img，ABL 会把 Android 的 DT 交给主线内核 → 黑屏。
> 用 `scripts/host/13-make-vendor-boot.sh` 以原厂 vendor_boot 为模板换进我们的 DTB
> （已实测：用原厂 DTB 重打包的结果与原厂文件逐字节相同）。

## 设备状态（以主线内核为准）

| 项 | 状态 | 备注 |
|---|---|---|
| 开机 / USB 网络 / SSH | 可用 | XEC 树自带 splash 延续，显示由面板驱动直接接管 |
| 屏幕 / 触控 | 可用 | 面板 `n11-42-02-0a-dsc`；触摸 Goodix gt9916 |
| 3D / 视频 | 可用 | Adreno 740 + zap 固件 |
| 蓝牙 | 可用 | WCN7850 |
| WiFi | 固件已就位，待实测 | 上游 wiki 标 N（页面滞后），固件包含 amss/board-2/regdb |
| 音频 | 未通 | 走 AudioReach，需要 topology + UCM，sheng 的 WCD938X UCM 不适用 |
| 4G / 短信 / 通话 | 未通 | 见下方「modem」 |
| 电池 / 充电 / 传感器 / 相机 / GPS / NFC | 未通 | 需要各自的驱动与注册表 |

**关于 modem**：本仓库会装 rmtfs / tqftpserv / qrtr-tools，并把 `QCOM_Q6V5_MSS`、
`QCOM_IPA`、`RMNET` 等从 `=m` 提为 `=y`（见 `vermeer-extra.config`）。
但主线 vermeer 的设备树里 **`&ipa` 节点还没启用**，所以首启后 `mmcli -L` 很可能仍看不到
modem —— 这属于设备树/驱动工作，不是构建脚本能解决的。通话更是需要 AudioReach
voice subgraph（主线没有任何 SoC 实现），不要指望靠改配置打开。

## 许可与第三方组件

本仓库是构建脚本集合，自身不声明开源许可证（上游 `ubuntu-sheng` / `debian-sheng` 亦未声明）。
仓库内包含的第三方内容：

| 内容 | 来源 | 许可 |
|---|---|---|
| `mkbootimg` | AOSP `system/tools/mkbootimg` | Apache-2.0 |
| `patches/adsprpcd-sensorspd.service` | 上游 `debian-sheng` 及其上游 | 随上游 |
| 构建期下载的内核 deb、设备固件 | 各自的 GitHub 仓库 | 见对应上游仓库 |

`firmware-xiaomi-vermeer` 在本仓库内只有包骨架（`DEBIAN/control`），**固件二进制在构建时
从上游 `linux-firmware-xiaomi-vermeer` 下载**，本仓库不重新分发；这些固件版权归高通 / 小米等
各自权利人，仅用于在自有设备上运行 Linux。

## 致谢

- **Xlie（Xlie-Electronic-Customs）** — vermeer 主线内核、固件包、Arch 生态与 IPA 移植指南
- **code002-2** — 上游构建流水线（本仓库的骨架）
- **map220v** / **ianchb** / **alghiffaryfa19** — sheng 主线移植与原始构建脚本
- **Dylan Van Assche** — `libssc` 与 `iio-sensor-proxy` 的 SSC 后端
