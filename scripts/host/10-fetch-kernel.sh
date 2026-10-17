#!/usr/bin/env bash
# 10-fetch-kernel.sh —— prebuilt 内核：从某个 release 里取 boot.img 与内核 deb
#
# 与 sheng 版本的差别：
#   * sheng 上游（ianchb/sm8550-mainline）每个 release 都带预打包的启动镜像
#     （boot_<机型>_dualboot*.img 这类文件），所以 prebuilt 是默认路径；
#   * vermeer 的上游（XEC/linux）只发源码树，没有任何 release 里带 boot.img，
#     因此本仓库默认走 kernel_source=custom_build（自己编）。prebuilt 仍然保留，
#     但必须显式给出 kernel_boot_pattern 与 kernel_releases_repo，否则直接报错，
#     而不是像 sheng 那样按固定文件名去猜。
#
# 环境变量：
#   BOOT_IMG_PATTERN      release 里 boot.img 的文件名（必需）
#   KERNEL_RELEASES_REPO  release 所在仓库（owner/repo，必需）
#   KERNEL_RELEASE        指定 tag；留空取最新
#   GH_TOKEN             GitHub Actions 自动注入
#
# 产出: boot.img、debs/linux-xiaomi-vermeer*.deb
#
# 用法: scripts/host/10-fetch-kernel.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/distro-env.sh
source "$HERE/../common/distro-env.sh"
# shellcheck source=../common/device-env.sh
source "$HERE/../common/device-env.sh"

REPO="${KERNEL_RELEASES_REPO:-}"
PATTERN="${BOOT_IMG_PATTERN:-}"
KERNEL_RELEASE="${KERNEL_RELEASE:-}"

if [[ -z "$REPO" || -z "$PATTERN" ]]; then
  cat >&2 <<'EOF'
[10-fetch-kernel] 错误：vermeer 没有现成的 boot.img release。
  上游 XEC/linux 只发布源码树，不带预打包启动镜像，因此：
    * 默认请用 kernel_source=custom_build（本仓库会自己编内核并生成 boot.img）；
    * 如果你确实把 boot.img 传到了某个 release，请同时给出
        kernel_releases_repo=<owner/repo>  kernel_boot_pattern=<文件名>
EOF
  exit 1
fi

mkdir -p debs

if [[ -n "$KERNEL_RELEASE" ]]; then
  TAG="$KERNEL_RELEASE"
  gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 \
    || die "指定的内核 release 不存在: $REPO@$TAG"
  log "使用 $REPO 的指定 release: $TAG"
else
  TAG="$(gh release list --repo "$REPO" --limit 1 --json tagName -q '.[0].tagName')"
  [[ -n "$TAG" ]] || die "无法获取 $REPO 的 release tag"
  log "使用 $REPO 的最新 release: $TAG"
fi

gh release download "$TAG" --repo "$REPO" \
  --pattern "$PATTERN" \
  --pattern "${KERNEL_DEB}*.deb" \
  --clobber --dir debs

[[ -f "debs/$PATTERN" ]] || die "未下载到 boot 镜像: $PATTERN（该 release 里可能没有这个变体）"
mv "debs/$PATTERN" boot.img

log "boot.img 就绪: $(du -h boot.img | cut -f1)"
ls -1 debs | sed 's/^/    /'
