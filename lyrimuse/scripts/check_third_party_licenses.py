#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LICENSES = ROOT / "THIRD_PARTY_LICENSES"

def spm_identities():
    doc = json.loads((ROOT / "lyrimuse/Package.resolved").read_text(encoding="utf-8"))

    pins = doc.get("pins") or (doc.get("object") or {}).get("pins") or []
    return [(pin.get("identity") or pin.get("package"), "lyrimuse/Package.resolved")
            for pin in pins if pin.get("identity") or pin.get("package")]

def brew_installs():
    found = []
    for line in (ROOT / "lyrimuse/build.sh").read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        for m in re.finditer(r"\bbrew install\s+([A-Za-z0-9._@/+-]+)", stripped):
            found.append((m.group(1).split("/")[-1], "lyrimuse/build.sh"))
    return found

def go_requires():
    found, in_block = [], False
    for line in (ROOT / "lyrimuse-collector/go.mod").read_text(encoding="utf-8").splitlines():
        code = line.split("//", 1)[0].strip()
        if not code:
            continue
        if code.startswith("require ("):
            in_block = True
            continue
        if in_block and code == ")":
            in_block = False
            continue
        m = re.match(r"^(?:require\s+)?(\S+)\s+v\S+$", code)
        if m and (in_block or code.startswith("require ")):
            found.append((m.group(1), "lyrimuse-collector/go.mod"))
    return found

def build_copies_licenses():
    for line in (ROOT / "lyrimuse/build.sh").read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("cp ") and "THIRD_PARTY_LICENSES" in stripped and "Contents/Resources" in stripped:
            return True
    return False

def main():
    if not LICENSES.exists():
        print(f"\u2717 找不到 {LICENSES}")
        return 1
    text = LICENSES.read_text(encoding="utf-8").lower()

    deps, seen = [], set()
    for name, src in spm_identities() + brew_installs() + go_requires():
        if name.lower() not in seen:
            seen.add(name.lower())
            deps.append((name, src))
    missing = [(name, src) for name, src in deps if name.lower() not in text]
    ok = True
    if not build_copies_licenses():
        ok = False
        print("\u2717 lyrimuse/build.sh 不再把 THIRD_PARTY_LICENSES 拷进 Contents/Resources/ —— "
              "「第三方许可」那一行只能退到 GitHub,随附条款就不满足了")
    if missing:
        ok = False
        print("\u2717 以下依赖没在 THIRD_PARTY_LICENSES 里声明(补一条:名字、来源链接、许可证、随附全文):")
        for name, src in missing:
            print(f"    {name}  \u2190 {src}")
    if ok:
        names = ", ".join(name for name, _ in deps)
        print(f"\u2713 THIRD_PARTY_LICENSES 覆盖 {len(deps)} 个随包分发的依赖:{names}")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
