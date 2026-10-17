#!/usr/bin/env python3
"""12-analyze-bootimg.py —— 从原厂 boot.img / vendor_boot.img / dtbo.img 反推参数

为什么需要它：K70(vermeer) 是 GKI/A-B 机型，boot 头结构、页大小、cmdline、DTB 位置
都必须与出厂镜像一致，靠猜（例如照抄 sheng 的 header_version 0）只会得到
`invalid boot image` 或直接不进系统。这个脚本按 AOSP 的结构原样解析，把结果
直接打印成可以填进 workflow 的输入值；`--extract DIR` 还能把里面的
kernel / ramdisk / dtb / bootconfig 拆出来（供 13-make-vendor-boot.sh 复用）。

用法：
    python3 scripts/host/12-analyze-bootimg.py stock-boot.img
    python3 scripts/host/12-analyze-bootimg.py vendor_boot.img
    python3 scripts/host/12-analyze-bootimg.py dtbo.img
    python3 scripts/host/12-analyze-bootimg.py vendor_boot.img --extract vb_out

注意：本脚本只读文件、不改任何东西（--extract 只往你指定的目录里写副本）。
"""
import os
import struct
import sys

BOOT_MAGIC = b"ANDROID!"
VENDOR_MAGIC = b"VNDRBOOT"
DTBO_MAGIC = struct.pack(">I", 0xd7B7AB1E)
VENDOR_RAMDISK_TABLE_ENTRY_SIZE = 108


def cstr(raw: bytes) -> str:
    return raw.split(b"\x00", 1)[0].decode("utf-8", "replace")


def align(n: int, page: int) -> int:
    return (n + page - 1) // page * page


def dump(path: str, offset: int, size: int, name: str) -> str:
    with open(path, "rb") as fh:
        fh.seek(offset)
        data = fh.read(size)
    os.makedirs(EXTRACT_DIR, exist_ok=True)
    out = os.path.join(EXTRACT_DIR, name)
    with open(out, "wb") as fh:
        fh.write(data)
    return out


def analyze_boot(path: str, data: bytes) -> dict:
    if data[:8] != BOOT_MAGIC:
        raise ValueError("不是 Android boot image（magic != ANDROID!）")

    hdr_version = struct.unpack_from("<I", data, 0x28)[0]
    if hdr_version > 4:                      # v0 的 0x28 处是 dt_size
        hdr_version = 0

    if hdr_version <= 2:
        kernel_size, kernel_addr = struct.unpack_from("<II", data, 0x08)
        ramdisk_size, ramdisk_addr = struct.unpack_from("<II", data, 0x10)
        second_size, second_addr = struct.unpack_from("<II", data, 0x18)
        tags_addr, pagesize = struct.unpack_from("<II", data, 0x20)
        info = dict(
            header_version=hdr_version, pagesize=pagesize,
            kernel_size=kernel_size, kernel_addr=kernel_addr,
            ramdisk_size=ramdisk_size, ramdisk_addr=ramdisk_addr,
            second_size=second_size, second_addr=second_addr,
            tags_addr=tags_addr,
            name=cstr(data[0x30:0x40]),
            cmdline=cstr(data[0x40:0x40 + 512]),
        )
        off = align(0x608 + 16, pagesize)      # v0/v1/v2 头 1632B + id/extra
        info["kernel_offset"] = off
        if EXTRACT_DIR:
            if kernel_size:
                info["extracted_kernel"] = dump(path, off, kernel_size, "kernel")
            off += align(kernel_size, pagesize)
            if ramdisk_size:
                info["extracted_ramdisk"] = dump(path, off, ramdisk_size, "ramdisk")
        return info

    # v3 / v4
    kernel_size, ramdisk_size, os_version, header_size = struct.unpack_from("<IIII", data, 0x08)
    signature_size = struct.unpack_from("<I", data, 0x4C)[0] if len(data) >= 0x50 else 0
    info = dict(
        header_version=struct.unpack_from("<I", data, 0x28)[0],
        pagesize=4096,                          # v3/v4 不存页大小
        kernel_size=kernel_size, ramdisk_size=ramdisk_size,
        header_size=header_size, signature_size=signature_size,
        os_version=os_version,
        cmdline=cstr(data[0x2C:0x2C + 1536]),
    )
    if EXTRACT_DIR:
        info["extracted_kernel"] = dump(path, header_size, kernel_size, "kernel")
        if ramdisk_size:
            info["extracted_ramdisk"] = dump(path, header_size + align(kernel_size, 4096), ramdisk_size, "ramdisk")
    return info


def analyze_vendor_boot(path: str, data: bytes) -> dict:
    if data[:8] != VENDOR_MAGIC:
        raise ValueError("不是 vendor_boot image（magic != VNDRBOOT）")
    version, pagesize = struct.unpack_from("<II", data, 0x08)
    kernel_addr, ramdisk_addr = struct.unpack_from("<II", data, 0x10)
    vendor_ramdisk_size = struct.unpack_from("<I", data, 0x18)[0]
    info = dict(
        header_version=version, pagesize=pagesize,
        kernel_addr=kernel_addr, ramdisk_addr=ramdisk_addr,
        vendor_ramdisk_size=vendor_ramdisk_size,
        vendor_cmdline=cstr(data[0x1C:0x1C + 2048]),
        tags_addr=struct.unpack_from("<I", data, 0x81C)[0],
        name=cstr(data[0x820:0x830]),
        header_size=struct.unpack_from("<I", data, 0x830)[0],
    )
    if version >= 4:
        info.update(
            dtb_size=struct.unpack_from("<I", data, 0x834)[0],
            dtb_addr=struct.unpack_from("<Q", data, 0x838)[0],
            ramdisk_table_size=struct.unpack_from("<I", data, 0x840)[0],
            ramdisk_table_entry_num=struct.unpack_from("<I", data, 0x844)[0],
            ramdisk_table_entry_size=struct.unpack_from("<I", data, 0x848)[0],
            bootconfig_size=struct.unpack_from("<I", data, 0x84C)[0],
        )
        # 数据区布局（AOSP mkbootimg write_vendor_boot_data）：
        #   header(page) | vendor_ramdisk(page) | dtb(page) | ramdisk_table(page) | bootconfig(page)
        off_ramdisk = align(info["header_size"], pagesize)
        off_dtb = off_ramdisk + align(info["vendor_ramdisk_size"], pagesize)
        off_table = off_dtb + align(info["dtb_size"], pagesize)
        off_bootconfig = off_table + align(info["ramdisk_table_size"], pagesize)
        info.update(off_ramdisk=off_ramdisk, off_dtb=off_dtb,
                    off_table=off_table, off_bootconfig=off_bootconfig)
        if EXTRACT_DIR:
            if info["vendor_ramdisk_size"]:
                info["extracted_vendor_ramdisk"] = dump(path, off_ramdisk, info["vendor_ramdisk_size"], "vendor_ramdisk")
            if info["dtb_size"]:
                info["extracted_dtb"] = dump(path, off_dtb, info["dtb_size"], "dtb")
            if info["bootconfig_size"]:
                info["extracted_bootconfig"] = dump(path, off_bootconfig, info["bootconfig_size"], "bootconfig")
    return info


def analyze_dtbo(path: str, data: bytes) -> dict:
    if data[:4] != DTBO_MAGIC:
        raise ValueError("不是 dtbo image（magic != 0xd7b7ab1e）")
    (magic, total_size, header_size, entry_size, entry_count,
     entries_offset, page_size, version) = struct.unpack_from(">8I", data, 0)
    return dict(magic=hex(magic), total_size=total_size, header_size=header_size,
                entry_size=entry_size, entry_count=entry_count,
                entries_offset=entries_offset, page_size=page_size, version=version)


def report_boot(info: dict) -> None:
    print(f"[boot header v{info['header_version']}] pagesize={info['pagesize']}")
    print()
    print("# ── 填进 workflow 的输入项 ──────────────────────────────")
    print(f"boot_header_version: {info['header_version']}")
    print(f"boot_pagesize: {info['pagesize']}")
    if info["header_version"] <= 2:
        print("boot_base: 0x00000000          # base 不在头里，用 0 即可")
        print(f"boot_kernel_offset: 0x{info['kernel_addr']:08x}")
        print(f"boot_ramdisk_offset: 0x{info['ramdisk_addr']:08x}")
        print(f"boot_tags_offset: 0x{info['tags_addr']:08x}")
    else:
        print("# header v3/v4 没有 base/offset 字段，mkbootimg 只需要 header_version + pagesize")
    print("# 原厂 cmdline（仅供比对，本仓库会写 root=PARTLABEL=...）:")
    print(f"#   {info['cmdline']}")
    print()
    print(f"kernel_size: {info['kernel_size']}  ramdisk_size: {info['ramdisk_size']}")
    head = ""
    if "extracted_kernel" in info:
        with open(info["extracted_kernel"], "rb") as fh:
            head = fh.read(4).hex()
        print(f"kernel 首字节: {head}"
              f"{'（MZ/EFI stub）' if head.startswith('4d5a') else ''}"
              f"{'（arm64 NOP 签名，CONFIG_EFI=n）' if head == '1f2003d5' else ''}")


def shell_vars(prefix: str, info: dict, keys=()) -> None:
    """把字段打印成 shell 可直接 eval 的形式（13-make-vendor-boot.sh 用）。"""
    for k in keys:
        if k not in info:
            continue
        v = info[k]
        name = f"{prefix}_{k.upper()}"
        if isinstance(v, int) and k.endswith(("addr", "offset")):
            print(f'{name}=0x{v:x}')
        elif isinstance(v, int):
            print(f"{name}={v}")
        else:
            escaped = str(v).replace("'", "'\\''")
            print(f"{name}='{escaped}'")


def report_vendor(info: dict) -> None:
    print(f"[vendor_boot v{info['header_version']}] pagesize={info['pagesize']} "
          f"header_size={info['header_size']}")
    print()
    print("# ── vendor_boot 里与主线启动相关的字段 ─────────────────")
    print(f"kernel_addr:  0x{info['kernel_addr']:08x}   → --base 0 --kernel_offset 0x{info['kernel_addr']:08x}")
    print(f"ramdisk_addr: 0x{info['ramdisk_addr']:08x}   → --ramdisk_offset 0x{info['ramdisk_addr']:08x}")
    print(f"tags_addr:    0x{info['tags_addr']:08x}   → --tags_offset 0x{info['tags_addr']:08x}")
    print(f"vendor_ramdisk_size: {info['vendor_ramdisk_size']}")
    if "dtb_size" in info:
        print(f"dtb_size: {info['dtb_size']}   dtb_addr: 0x{info['dtb_addr']:x}"
              f"   → --dtb_offset 0x{info['dtb_addr']:08x}")
        print(f"dtb 位置（文件内偏移）: 0x{info['off_dtb']:x}")
        print(f"ramdisk table: {info['ramdisk_table_entry_num']} 条, "
              f"entry_size={info['ramdisk_table_entry_size']}, "
              f"size={info['ramdisk_table_size']}")
        print(f"bootconfig_size: {info['bootconfig_size']}（偏移 0x{info['off_bootconfig']:x}）")
    print()
    print("vendor_cmdline:")
    print(f"  {info['vendor_cmdline']}")


def main(argv: list) -> int:
    global EXTRACT_DIR, SHELL_OUT
    path = None
    EXTRACT_DIR = ""
    SHELL_OUT = False
    rest = argv[1:]
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--extract":
            if i + 1 >= len(rest):
                print("--extract 需要一个目录参数", file=sys.stderr)
                return 2
            EXTRACT_DIR = rest[i + 1]
            i += 2
            continue
        if a.startswith("--extract="):
            EXTRACT_DIR = a.split("=", 1)[1]
            i += 1
            continue
        if a == "--shell":
            SHELL_OUT = True
            i += 1
            continue
        if path is None:
            path = a
        i += 1

    if path is None:
        print(__doc__)
        return 2
    with open(path, "rb") as fh:
        head = fh.read(8)

    if head == BOOT_MAGIC:
        with open(path, "rb") as fh:
            data = fh.read(4096 * 2)
        info = analyze_boot(path, data)
        if SHELL_OUT:
            shell_vars("B", info, ("header_version", "pagesize", "kernel_size",
                                   "ramdisk_size", "kernel_addr", "ramdisk_addr",
                                   "second_addr", "tags_addr", "cmdline"))
        else:
            report_boot(info)
        return 0

    if head == VENDOR_MAGIC:
        with open(path, "rb") as fh:
            data = fh.read(4096 * 2)
        info = analyze_vendor_boot(path, data)
        if SHELL_OUT:
            shell_vars("VB", info, ("header_version", "pagesize", "header_size",
                                    "kernel_addr", "ramdisk_addr", "tags_addr",
                                    "vendor_ramdisk_size", "dtb_size", "dtb_addr",
                                    "ramdisk_table_entry_num", "bootconfig_size",
                                    "vendor_cmdline", "off_dtb", "off_ramdisk",
                                    "off_bootconfig", "off_table"))
        else:
            report_vendor(info)
        return 0

    if head[:4] == DTBO_MAGIC:
        with open(path, "rb") as fh:
            data = fh.read(4096)
        info = analyze_dtbo(path, data)
        print("[dtbo]")
        for k, v in info.items():
            print(f"  {k}: {v}")
        return 0

    print("无法识别的镜像（ANDROID! / VNDRBOOT / dtbo 魔数都不匹配）", file=sys.stderr)
    return 1


EXTRACT_DIR = ""
SHELL_OUT = False

if __name__ == "__main__":
    sys.exit(main(sys.argv))
