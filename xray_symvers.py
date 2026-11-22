#!/usr/bin/env python3
"""
File (CI Repo): xray_symvers.py
功能：将设备 kmi_baseline.json 中全部 355 项符号与编译产出的 vmlinux.symvers 做全量交叉比对，精准定性 CRC 漂移范围
用法：python3 xray_symvers.py --baseline kmi_baseline.json --symvers gki66_v4l2_build/common/Module.symvers --out crc_xray_report.json
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def load_symvers(path: Path) -> dict[str, str]:
    syms: dict[str, str] = {}
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) >= 2:
                syms[parts[1]] = parts[0].lower()
    return syms


def main() -> int:
    p = argparse.ArgumentParser(description="全量基线符号 CRC X 光透视器")
    p.add_argument("--baseline", type=Path, required=True)
    p.add_argument("--symvers", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()

    base_data = json.loads(args.baseline.read_text(encoding="utf-8"))
    dev_syms: dict[str, str] = {k: v.lower() for k, v in base_data.get("symbols", {}).items()}
    built_syms = load_symvers(args.symvers)

    matched: list[str] = []
    mismatched: list[dict[str, str]] = []
    missing_in_built: list[str] = []

    for sym, dev_crc in sorted(dev_syms.items()):
        if sym not in built_syms:
            missing_in_built.append(sym)
        elif built_syms[sym] == dev_crc:
            matched.append(sym)
        else:
            mismatched.append({"symbol": sym, "device": dev_crc, "built": built_syms[sym]})

    compared = len(matched) + len(mismatched)
    match_rate = round((len(matched) / compared) * 100.0, 2) if compared else 0.0

    v4l2_mismatches = [m for m in mismatched if any(t in m["symbol"] for t in ("video", "v4l2", "vb2", "media"))]
    v4l2_matches = [s for s in matched if any(t in s for t in ("video", "v4l2", "vb2", "media"))]

    if compared == 0:
        verdict = "NO_OVERLAP"
    elif len(mismatched) == 0:
        verdict = "PERFECT_MATCH"
    elif match_rate >= 90.0:
        verdict = "LOCALIZED_STRUCT_DELTA (超过 90% 符号完全一致，属于局部结构体/宏开关差异，精准对齐配置或单处补丁即可命中)"
    elif match_rate >= 40.0:
        verdict = "VENDOR_CORE_PATCH_DELTA (核心基干结构体被厂商补丁改写，需改用三星 SM-X520 官方开源内核树)"
    else:
        verdict = "GLOBAL_KMI_MISMATCH (全局 KMI / 编译器或基础配置严重偏移)"

    report: dict[str, Any] = {
        "summary": {
            "device_baseline_total": len(dev_syms),
            "built_symvers_total": len(built_syms),
            "compared_common": compared,
            "matched_count": len(matched),
            "mismatched_count": len(mismatched),
            "missing_in_built_count": len(missing_in_built),
            "match_rate_percent": match_rate,
            "v4l2_matched_count": len(v4l2_matches),
            "v4l2_mismatched_count": len(v4l2_mismatches),
            "verdict": verdict,
        },
        "v4l2_mismatches": v4l2_mismatches,
        "mismatched_symbols": mismatched,
        "missing_in_built": missing_in_built,
    }
    args.out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print("=== 355 项基线符号 CRC 全量 X 光透视报告 ===")
    print(f"可比对交集符号 : {compared} (缺失={len(missing_in_built)})")
    print(f"精确匹配数     : {len(matched)} / {compared} ({match_rate}%)")
    print(f"V4L2 符号状态  : 匹配={len(v4l2_matches)}, 冲突={len(v4l2_mismatches)}")
    print(f"架构定性结论   : {verdict}")

    if mismatched:
        print("\n前 25 项冲突符号样本：")
        for m in mismatched[:25]:
            print(f"  {m['symbol']:34s} device={m['device']} vs built={m['built']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
