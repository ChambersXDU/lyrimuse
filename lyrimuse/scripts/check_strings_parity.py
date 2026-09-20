#!/usr/bin/env python3
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / "Sources/lyrimuse/Resources"
FILES = {
    "zh-hans": BASE / "zh-hans.lproj/Localizable.strings",
    "en": BASE / "en.lproj/Localizable.strings",
    "zh-hant": BASE / "zh-hant.lproj/Localizable.strings",
}

ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)

CALL = re.compile(r'L10n\.t\(\s*"((?:[^"\\]|\\.)*)"')

def keys_of(path):
    return [m.group(1) for m in ENTRY.finditer(path.read_text(encoding="utf-8"))]

def source_literals():
    found = {}
    for path in sorted((ROOT / "Sources/lyrimuse").rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        for m in CALL.finditer(text):
            found.setdefault(
                m.group(1),
                f"{path.relative_to(ROOT)}:{text.count(chr(10), 0, m.start()) + 1}",
            )
    return found

def main():
    tables, dupes = {}, {}
    for lang, path in FILES.items():
        if not path.exists():
            print(f"\u2717 缺文件: {path}")
            return 1
        ks = keys_of(path)
        print(f"  {lang}: {len(ks)} 条")
        seen, dup = set(), set()
        for k in ks:
            (dup if k in seen else seen).add(k)
        if dup:
            dupes[lang] = sorted(dup)
        tables[lang] = seen

    ok = True
    only_zh = sorted(tables["zh-hans"] - tables["en"])
    only_en = sorted(tables["en"] - tables["zh-hans"])
    if only_zh:
        ok = False
        print(f"\n\u2717 只在 zh-hans 有、en 缺失({len(only_zh)} 条) —— 英文界面会显示中文原文:")
        for k in only_zh[:20]:
            print(f"    {k}")
        if len(only_zh) > 20:
            print(f"    …还有 {len(only_zh) - 20} 条")
    if only_en:
        ok = False
        print(f"\n\u2717 只在 en 有、zh-hans 缺失({len(only_en)} 条):")
        for k in only_en[:20]:
            print(f"    {k}")

    import json
    catalog = json.loads((ROOT / "Localization/Localizable.xcstrings").read_text(encoding="utf-8"))
    for lang in ("en", "zh-Hant"):
        lacking = sorted(k for k, v in (catalog.get("strings") or {}).items()
                         if not ((((v or {}).get("localizations") or {}).get(lang) or {}).get("stringUnit") or {}).get("value"))
        if lacking:
            ok = False
            print(f"\n\u2717 catalog 里 {len(lacking)} 个键缺 {lang} 翻译(新加文案必须三语齐全,繁体规范见 Localization/zh-Hant-STYLE.md):")
            for k in lacking[:20]:
                print(f"    {k[:80]}")

    hant_mismatch = sorted(tables["zh-hant"] ^ tables["zh-hans"])
    if hant_mismatch:
        ok = False
        print(f"\n\u2717 zh-hant 与 zh-hans 的 key 集不一致({len(hant_mismatch)} 条) —— 生成物只能由 generate-strings.py 生成:")
        for k in hant_mismatch[:20]:
            print(f"    {k}")
    for lang, ks in dupes.items():
        ok = False
        print(f"\n\u2717 {lang} 有重复 key({len(ks)} 条) —— .strings 只保留最后一条,前面的静默失效:")
        for k in ks[:20]:
            print(f"    {k}")

    registered = tables["zh-hans"] | tables["en"]
    literals = source_literals()
    unregistered = sorted(set(literals) - registered)
    print(f"  源码 L10n.t 字面量: {len(literals)} 条")
    if unregistered:
        ok = False
        print(f"\n\u2717 源码用了、两份表都没登记({len(unregistered)} 条) —— 英文界面会原样显示中文:")
        for k in unregistered[:20]:
            print(f"    {k[:70]}")
            print(f"      \u21b3 {literals[k]}")
        if len(unregistered) > 20:
            print(f"    …还有 {len(unregistered) - 20} 条")

    print("\n\u2713 三份 .strings 的 key 一致,源码用到的串也都登记过" if ok
          else "\n上面的差异会造成运行时静默 fallback,请补齐")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
