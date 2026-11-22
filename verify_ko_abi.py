#!/usr/bin/env python3
"""
File (Debian / x86_64 Build Host): verify_ko_abi.py
功能：零外部依赖解析 ARM64 内核模块 (.ko) ELF64 .modinfo 与 __versions CRC 表，充当 insmod 前的零 Panic 门禁
用法：
  1. 在平板提取基准: python3 verify_ko_abi.py extract --out kmi_baseline.json /path/to/fimc_is.ko /path/to/exynos_mfc.ko /path/to/cfg80211.ko
  2. 编译后加载门禁: python3 verify_ko_abi.py gate --baseline kmi_baseline.json --ko v4l2loopback.ko
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

ELF_MAGIC = b"\x7fELF"
ELFCLASS64 = 2
ELFDATA2LSB = 1
EM_AARCH64 = 183
MODVERSION_ENTRY_SIZE = 64  # sizeof(unsigned long)=8 + MODULE_NAME_LEN=56 on aarch64


@dataclass(frozen=True)
class KoMetadata:
    path: str
    machine: int
    vermagic: str
    has_kcfi_hint: bool
    symbols: dict[str, str]  # symbol_name -> "0x1234abcd"


def parse_elf64_sections(data: bytes) -> tuple[int, dict[str, bytes]]:
    if len(data) < 64 or data[:4] != ELF_MAGIC:
        raise ValueError("不是合法的 ELF 文件")
    if data[4] != ELFCLASS64 or data[5] != ELFDATA2LSB:
        raise ValueError("仅支持 64 位小端 ELF (ELF64 LSB)")

    e_machine = struct.unpack_from("<H", data, 18)[0]
    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 58)

    if e_shoff == 0 or e_shnum == 0:
        raise ValueError("ELF 缺少 Section Header Table")

    def read_shdr(idx: int) -> tuple[int, int, int]:
        off = e_shoff + idx * e_shentsize
        sh_name = struct.unpack_from("<I", data, off)[0]
        sh_offset, sh_size = struct.unpack_from("<QQ", data, off + 24)
        return sh_name, sh_offset, sh_size

    _, str_off, str_size = read_shdr(e_shstrndx)
    shstrtab = data[str_off : str_off + str_size]

    sections: dict[str, bytes] = {}
    for i in range(e_shnum):
        sh_name, sh_offset, sh_size = read_shdr(i)
        end = shstrtab.find(b"\x00", sh_name)
        name = shstrtab[sh_name : end if end != -1 else len(shstrtab)].decode("utf-8", errors="replace")
        if name in (".modinfo", "__versions", ".kcfi_traps", ".symtab", ".strtab"):
            sections[name] = data[sh_offset : sh_offset + sh_size]
    return e_machine, sections


def inspect_ko(ko_path: Path) -> KoMetadata:
    raw = ko_path.read_bytes()
    machine, sections = parse_elf64_sections(raw)

    vermagic = ""
    if ".modinfo" in sections:
        for entry in sections[".modinfo"].split(b"\x00"):
            if entry.startswith(b"vermagic="):
                vermagic = entry.decode("utf-8", errors="replace").split("=", 1)[1]
                break

    symbols: dict[str, str] = {}
    if "__versions" in sections:
        ver_sec = sections["__versions"]
        count = len(ver_sec) // MODVERSION_ENTRY_SIZE
        for i in range(count):
            crc_u64, name_raw = struct.unpack_from("<Q56s", ver_sec, i * MODVERSION_ENTRY_SIZE)
            sym_name = name_raw.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
            if sym_name:
                symbols[sym_name] = f"0x{crc_u64 & 0xFFFFFFFF:08x}"

    has_kcfi = ".kcfi_traps" in sections or (b"__kcfi_typeid_" in sections.get(".strtab", b""))
    return KoMetadata(
        path=str(ko_path),
        machine=machine,
        vermagic=vermagic,
        has_kcfi_hint=has_kcfi,
        symbols=symbols,
    )


def cmd_extract(ko_files: list[Path], out_path: Path) -> int:
    merged_symbols: dict[str, str] = {}
    vermagics: list[str] = []
    kcfi_detected = False

    for p in ko_files:
        if not p.is_file():
            print(f"[SKIP] 文件不存在: {p}", file=sys.stderr)
            continue
        meta = inspect_ko(p)
        if meta.machine != EM_AARCH64:
            print(f"[WARN] 非 aarch64 模块跳过: {p} (machine={meta.machine})", file=sys.stderr)
            continue
        if meta.vermagic:
            vermagics.append(meta.vermagic)
        kcfi_detected = kcfi_detected or meta.has_kcfi_hint
        merged_symbols.update(meta.symbols)
        print(f"[READ] {p.name}: vermagic='{meta.vermagic}', symbols={len(meta.symbols)}, kcfi={meta.has_kcfi_hint}")

    if not vermagics:
        print("[FAIL] 未能从输入模块中提取有效基线", file=sys.stderr)
        return 1

    baseline: dict[str, Any] = {
        "vermagic_sample": vermagics[0],
        "kmi_prefix": vermagics[0].split("-ab", 1)[0] if "-ab" in vermagics[0] else vermagics[0].split(" ", 1)[0],
        "kcfi_detected": kcfi_detected,
        "symbol_count": len(merged_symbols),
        "symbols": dict(sorted(merged_symbols.items())),
    }
    out_path.write_text(json.dumps(baseline, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"[PASS] KMI 基准已导出: {out_path} (kmi_prefix={baseline['kmi_prefix']}, kcfi={kcfi_detected}, symbols={len(merged_symbols)})")
    print(f"       module_layout CRC = {merged_symbols.get('module_layout', 'MISSING')}")
    return 0


def cmd_gate(baseline_path: Path, target_ko: Path) -> int:
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    meta = inspect_ko(target_ko)

    errors: list[str] = []
    matched_syms = 0

    if meta.machine != EM_AARCH64:
        errors.append(f"架构不匹配: expect EM_AARCH64({EM_AARCH64}), actual={meta.machine}")

    kmi_prefix = baseline["kmi_prefix"]
    if not meta.vermagic.startswith(kmi_prefix):
        errors.append(f"KMI vermagic 前缀不匹配: expect='{kmi_prefix}*', actual='{meta.vermagic}'")

    for token in ("SMP", "preempt", "mod_unload", "modversions", "aarch64"):
        if token not in meta.vermagic:
            errors.append(f"vermagic 缺失关键编译标识: {token} (actual='{meta.vermagic}')")

    if baseline.get("kcfi_detected") and not meta.has_kcfi_hint:
        errors.append("目标内核已启用 KCFI，但编译出的 .ko 未检测到 KCFI 段（禁止加载，否则必触发 Panic！）")

    base_syms: dict[str, str] = baseline.get("symbols", {})
    if "module_layout" not in meta.symbols:
        errors.append("编译出的 .ko 缺少 module_layout 符号（未开启 CONFIG_MODVERSIONS）")
    elif "module_layout" in base_syms and meta.symbols["module_layout"] != base_syms["module_layout"]:
        errors.append(
            f"module_layout CRC 冲突: device={base_syms['module_layout']} vs ko={meta.symbols['module_layout']}"
        )

    for sym, crc in meta.symbols.items():
        if sym in base_syms:
            if base_syms[sym] != crc:
                errors.append(f"符号 CRC 冲突 [{sym}]: device={base_syms[sym]} vs ko={crc}")
            else:
                matched_syms += 1

    print("=== v4l2loopback.ko 零 Panic ELF ABI 门禁报告 ===")
    print(f"目标模块     : {target_ko}")
    print(f"目标 vermagic: {meta.vermagic}")
    print(f"KCFI 特征    : {meta.has_kcfi_hint} (设备基准={baseline.get('kcfi_detected')})")
    print(f"交集符号校验 : 通过 {matched_syms} 项 (总引用 {len(meta.symbols)} 项)")

    if errors:
        print("\n[BLOCKED] 发现以下致命 ABI 冲突，严禁执行 insmod：")
        for e in errors:
            print(f"  - {e}")
        return 1

    print("\n[APPROVED] 所有 KMI / vermagic / KCFI / 符号 CRC 100% 对齐，允许安全加载！")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="Android 15 GKI 6.6 LKM 零 Panic ELF ABI 门禁工具")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_ext = sub.add_parser("extract", help="从设备原厂 .ko 提取真实 KMI/CRC 基准")
    p_ext.add_argument("--out", type=Path, required=True)
    p_ext.add_argument("ko_files", nargs="+", type=Path)

    p_gate = sub.add_parser("gate", help="加载前强校验编译产物 v4l2loopback.ko")
    p_gate.add_argument("--baseline", type=Path, required=True)
    p_gate.add_argument("--ko", type=Path, required=True)

    args = p.parse_args()
    if args.cmd == "extract":
        return cmd_extract(args.ko_files, args.out)
    return cmd_gate(args.baseline, args.ko)


if __name__ == "__main__":
    raise SystemExit(main())
