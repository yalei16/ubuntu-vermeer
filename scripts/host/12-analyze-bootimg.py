#!/usr/bin/env python3
"""12-analyze-bootimg.py —— 从原厂 boot.img / vendor_boot.img 反推 mkbootimg 参数

为什么需要它：K70(vermeer) 是 GKI/A-B 机型，boot 头结构、页大小、cmdline 都
必须与出厂镜像一致，靠猜（例如照抄 sheng 的 header_version 0）只会得到
`invalid boot image` 或直接不进系统。这个脚本按 AOSP boot image header
v0–v4 的原样结构解析，把结果直接打印成可以直接填进 workflow 的输入值。

用法：
    python3 scripts/host/12-analyze-bootimg.py stock-boot.img
    python3 scripts/host/12-analyze-bootimg.py vendor_boot.img     # 也能认

输出（示例）：
    [boot header v4] pagesize=4096
    boot_header_version: 4
    boot_pagesize: 4096
    cmdline: root=PARTLABEL=linux rootwait
    ...

注意：本脚本只读文件、不改任何东西。
"""
import struct
import sys

BOOT_MAGIC = b"ANDROID!"
VENDOR_MAGIC = b"VNDRBOOT"


def cstr(raw: bytes) -> str:
    return raw.split(b"\x00", 1)[0].decode("utf-8", "replace")


def analyze_boot(data: bytes) -> dict:
    if data[:8] != BOOT_MAGIC:
        raise ValueError("不是 Android boot image（magic != ANDROID!）")

    hdr_version = struct.unpack_from("<I", data, 0x28)[0] if len(data) >= 0x2C else 0

    # header v0/v1 在 0x28 处是 dt_size，不是 header_version —— 用 os_version 判别：
    # v0 的 0x2C 处是 os_version 的两个 halfword（通常 0），这里用 0x28 与
    # 0x2C 同时非 0 且 0x28 很小的启发式不安全，因此按 0x28 的合法取值区间判断。
    if hdr_version > 4:
        hdr_version = 0  # 0x28 处不是 header_version，说明是 v0

    if hdr_version <= 2:
        kernel_size, kernel_addr = struct.unpack_from("<II", data, 0x08)
        ramdisk_size, ramdisk_addr = struct.unpack_from("<II", data, 0x10)
        second_size, second_addr = struct.unpack_from("<II", data, 0x18)
        tags_addr, pagesize = struct.unpack_from("<II", data, 0x20)
        cmdline = cstr(data[0x40:0x40 + 512])
        name = cstr(data[0x30:0x40])
        result = dict(
            header_version=hdr_version,
            pagesize=pagesize,
            kernel_size=kernel_size,
            kernel_offset=kernel_addr,
            ramdisk_size=ramdisk_size,
            ramdisk_offset=ramdisk_addr,
            second_size=second_size,
            second_offset=second_addr,
            tags_offset=tags_addr,
            name=name,
            cmdline=cmdline,
        )
        if hdr_version == 2:
            dtb_size, dtb_addr = struct.unpack_from("<QQ", data, 0x400 + 8)
            result.update(dtb_size=dtb_size, dtb_addr=dtb_addr)
        return result

    # v3/v4：magic(8) kernel_size(4) ramdisk_size(4) os_version(4) header_size(4)
    #       reserved[4](16) header_version(4) cmdline[1536]
    kernel_size, ramdisk_size, os_version, header_size = struct.unpack_from("<IIII", data, 0x08)
    stored_version = struct.unpack_from("<I", data, 0x28)[0]
    cmdline = cstr(data[0x2C:0x2C + 1536])
    return dict(
        header_version=stored_version,
        pagesize=4096,  # v3/v4 不存页大小，固定 4096
        kernel_size=kernel_size,
        ramdisk_size=ramdisk_size,
        header_size=header_size,
        os_version=f"{os_version >> 25}.{(os_version >> 18) & 0x7F}.{(os_version >> 11) & 0x7F}",
        cmdline=cmdline,
    )


def analyze_vendor_boot(data: bytes) -> dict:
    if data[:8] != VENDOR_MAGIC:
        raise ValueError("不是 vendor_boot image（magic != VNDRBOOT）")
    version, pagesize = struct.unpack_from("<II", data, 0x08)
    kernel_addr, ramdisk_addr = struct.unpack_from("<II", data, 0x10)
    vendor_ramdisk_size = struct.unpack_from("<I", data, 0x18)[0]
    cmdline = cstr(data[0x1C:0x1C + 2048])
    return dict(
        header_version=version,
        pagesize=pagesize,
        kernel_addr=kernel_addr,
        ramdisk_addr=ramdisk_addr,
        vendor_ramdisk_size=vendor_ramdisk_size,
        vendor_cmdline=cmdline,
    )


def main(argv: list) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    with open(argv[1], "rb") as fh:
        data = fh.read()

    if data[:8] == BOOT_MAGIC:
        info = analyze_boot(data)
        print(f"[boot header v{info['header_version']}] pagesize={info['pagesize']}")
        print()
        print("# ── 填进 workflow 的输入项 ──────────────────────────────")
        print(f"boot_header_version: {info['header_version']}")
        print(f"boot_pagesize: {info['pagesize']}")
        if info["header_version"] <= 2:
            print(f"boot_base: 0x{0:08x}          # base 不在头里，用 0 即可")
            print(f"boot_kernel_offset: 0x{info['kernel_offset']:08x}")
            print(f"boot_ramdisk_offset: 0x{info['ramdisk_offset']:08x}")
            print(f"boot_tags_offset: 0x{info['tags_offset']:08x}")
        else:
            print("# header v3/v4 没有 base/offset 字段，mkbootimg 只需要 header_version + pagesize")
        print(f"# 原厂 cmdline（仅供比对，本仓库会写 root=PARTLABEL=...）:")
        print(f"#   {info['cmdline']}")
        print()
        print(f"kernel_size: {info['kernel_size']}  ramdisk_size: {info['ramdisk_size']}")
        return 0

    if data[:8] == VENDOR_MAGIC:
        info = analyze_vendor_boot(data)
        print(f"[vendor_boot v{info['header_version']}] pagesize={info['pagesize']}")
        print(f"vendor_ramdisk_size: {info['vendor_ramdisk_size']}")
        print(f"vendor_cmdline:\n  {info['vendor_cmdline']}")
        print()
        print("# 主线的启动镜像只用 boot 分区；vendor_boot 保持原厂即可，")
        print("# 但 cmdline 里的 console=/earlycon 等信息对调试有用。")
        return 0

    print("无法识别的镜像（既不是 ANDROID! 也不是 VNDRBOOT）", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
