#!/usr/bin/env python3
"""
File (CI Repo): diff_kconfig.py
功能：比对平板原版 device_config.gz 与 CI olddefconfig 后的 common/.config，精准暴露被丢弃或被静默翻转的 ABI 开关
用法：python3 diff_kconfig.py --device device_config.gz --built gki66_v4l2_build/common/.config --out kconfig_diff.json
"""
from __future__ import annotations

import argparse
import gzip
import json
import re
from pathlib import Path
from typing import Any

HIGH_RISK_RE = re.compile(
    r"(MODULE|MODVERSION|BTF|CFI|LTO|KABI|OEM|GKI|RKP|KDP|UH|SEC_|FIVE|PROCA|"
    r"TRACE|FTRACE|LIVEPATCH|KALLSYMS|RANDSTRUCT|KASAN|KCSAN|LOCKDEP|PROVE_LOCKING|KSU|SUSFS|V4L|VIDEO)"
)


def load_kconfig(path: Path) -> dict[str, str]:
    opener = gzip.open if path.suffix == ".gz" else open
    res: dict[str, str] = {}
    with opener(path, "rt", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            if line.startswith("# CONFIG_") and line.endswith(" is not set"):
                res[line[2 : -len(" is not set")]] = "n"
            elif line.startswith("CONFIG_") and "=" in line:
                k, v = line.split("=", 1)
                res[k] = v
    return res


def main() -> int:
    p = argparse.ArgumentParser(description="比对 device_config.gz 与 olddefconfig 产物差异")
    p.add_argument("--device", type=Path, required=True)
    p.add_argument("--built", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()

    dev = load_kconfig(args.device)
    built = load_kconfig(args.built)

    dropped_enabled: list[dict[str, str]] = []
    flipped_values: list[dict[str, str]] = []
    added_enabled: list[dict[str, str]] = []

    for k, dv in sorted(dev.items()):
        if k not in built:
            if dv != "n":
                dropped_enabled.append({"key": k, "device": dv, "built": "<DROPPED>"})
        elif built[k] != dv:
            flipped_values.append({"key": k, "device": dv, "built": built[k]})

    for k, bv in sorted(built.items()):
        if k not in dev and bv != "n":
            added_enabled.append({"key": k, "device": "<ABSENT>", "built": bv})

    high_risk_dropped = [x for x in dropped_enabled if HIGH_RISK_RE.search(x["key"])]
    high_risk_flipped = [x for x in flipped_values if HIGH_RISK_RE.search(x["key"])]
    high_risk_added = [x for x in added_enabled if HIGH_RISK_RE.search(x["key"])]

    report: dict[str, Any] = {
        "counts": {
            "dropped_enabled": len(dropped_enabled),
            "flipped_values": len(flipped_values),
            "added_enabled": len(added_enabled),
            "high_risk_dropped": len(high_risk_dropped),
            "high_risk_flipped": len(high_risk_flipped),
        },
        "high_risk_dropped": high_risk_dropped,
        "high_risk_flipped": high_risk_flipped,
        "high_risk_added": high_risk_added,
        "all_dropped_enabled": dropped_enabled,
        "all_flipped_values": flipped_values,
    }
    args.out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print("=== Kconfig 差异审计摘要 (device_config.gz vs olddefconfig) ===")
    print(f"被 AOSP 源码树彻底丢弃的启用项 : {len(dropped_enabled)} (高危 ABI 相关: {len(high_risk_dropped)})")
    print(f"被 olddefconfig 静默改值的项  : {len(flipped_values)} (高危 ABI 相关: {len(high_risk_flipped)})")
    print(f"AOSP 新增默认启用项           : {len(added_enabled)} (高危 ABI 相关: {len(high_risk_added)})")

    if high_risk_flipped:
        print("\n[HIGH_RISK_FLIPPED] 以下敏感开关在 olddefconfig 中被改值：")
        for x in high_risk_flipped[:30]:
            print(f"  {x['key']}: device={x['device']} -> built={x['built']}")

    if high_risk_dropped:
        print("\n[HIGH_RISK_DROPPED] 以下设备启用项在当前源码树中完全不存在：")
        for x in high_risk_dropped[:30]:
            print(f"  {x['key']}={x['device']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
