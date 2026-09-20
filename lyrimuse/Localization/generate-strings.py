#!/usr/bin/env python3
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(ROOT, "Localizable.xcstrings")
TARGETS = {
    "zh-Hans": "zh-hans.lproj",
    "en": "en.lproj",
    "zh-Hant": "zh-hant.lproj",
}

FALLBACK_TO_SOURCE = set()
OUT_DIR = os.path.join(ROOT, "..", "Sources", "lyrimuse", "Resources")

HEADER = ""

XCODE_SEPARATORS = (",", " : ")

def head_key_order():
    try:
        r = subprocess.run(["git", "-C", ROOT, "show", "HEAD:./Localizable.xcstrings"],
                           capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return None
        return list(json.loads(r.stdout).get("strings", {}).keys())
    except Exception:
        return None

def reordered_against_head(catalog):
    order = head_key_order()
    if not order:
        return None
    cur = list(catalog.get("strings", {}).keys())
    common = set(order) & set(cur)
    return [k for k in order if k in common] != [k for k in cur if k in common]

def canonical_text(catalog) -> str:
    return json.dumps(catalog, ensure_ascii=False, indent=2, separators=XCODE_SEPARATORS) + "\n"

def check_canonical_form(raw: str, catalog, normalize: bool) -> int:
    reordered = reordered_against_head(catalog)
    want = canonical_text(catalog)
    if want == raw and not reordered:
        return 0
    if normalize:
        if reordered:

            order = head_key_order() or []
            cur = catalog["strings"]
            fixed = {k: cur[k] for k in order if k in cur}
            for k in sorted(set(cur) - set(fixed)):
                fixed[k] = cur[k]
            catalog["strings"] = fixed
            want = canonical_text(catalog)

        assert json.loads(want) == json.loads(raw), "规范化前后内容不等价 —— 拒绝写入"
        with open(CATALOG, "w", encoding="utf-8") as f:
            f.write(want)
        print("\u2713 catalog 已就地规范化成 Xcode 风格" +
              ("、键序已放回 HEAD 的次序" if reordered else "") + "(内容未变)")
        return 0

    problems = []
    if want != raw:
        problems.append(
            "排版不是 Xcode 的写法 —— 应为 `\"key\" : value`(冒号前有空格),"
            "而 json.dump(..., indent=2) 的默认写法是 `\"key\": value`")
    if reordered:
        problems.append(
            "键序被整体重排过(跟 HEAD 比)—— 每个键都会显示成「删一行 + 加一行」,"
            "多半是 sorted(d[\"strings\"].items()) 干的")
    print(
        "\u2717 Localizable.xcstrings 的序列化不规范 —— 它会让 git diff 从几十行炸成几万行:",
        file=sys.stderr)
    for p in problems:
        print("  \u2022 " + p, file=sys.stderr)
    print(
        "  就地修正(只改排版和次序、内容一个字不动):\n"
        "      python3 Localization/generate-strings.py --normalize\n"
        "  以后用 Python 改这个文件,记得带 separators=(',', ' : ') 且别排序。",
        file=sys.stderr,
    )
    return 1

def escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")

def main() -> int:
    normalize = "--normalize" in sys.argv[1:]
    with open(CATALOG, encoding="utf-8") as f:
        raw = f.read()
    catalog = json.loads(raw)
    if check_canonical_form(raw, catalog, normalize) != 0:
        return 1
    if catalog.get("sourceLanguage") != "zh-Hans":
        print(f"sourceLanguage 应为 zh-Hans,实际是 {catalog.get('sourceLanguage')!r}", file=sys.stderr)
        return 1
    strings = catalog.get("strings") or {}
    if not strings:
        print("catalog 里一个键都没有 —— 拒绝生成空文件覆盖现有翻译", file=sys.stderr)
        return 1
    for lang, lproj in TARGETS.items():
        lines = [HEADER]
        fallback_count = 0
        missing = []
        for key in sorted(strings):
            entry = strings[key] or {}
            unit = ((entry.get("localizations") or {}).get(lang) or {}).get("stringUnit") or {}
            value = unit.get("value")
            if value is None:

                if lang == catalog["sourceLanguage"]:
                    value = key
                elif lang in FALLBACK_TO_SOURCE:
                    src = ((entry.get("localizations") or {}).get(catalog["sourceLanguage"]) or {}).get("stringUnit") or {}
                    value = src.get("value") or key
                    fallback_count += 1
                else:
                    missing.append(key)
                    continue
            lines.append(f'"{escape(key)}" = "{escape(value)}";\n')
        out = os.path.join(OUT_DIR, lproj, "Localizable.strings")
        with open(out, "w", encoding="utf-8") as f:
            f.writelines(lines)
        if missing:
            print(f"\u2717 {lang} 缺 {len(missing)} 条翻译(新加文案必须把 en / zh-Hant 都写全,繁体规范见 Localization/zh-Hant-STYLE.md):", file=sys.stderr)
            for key in missing[:20]:
                print(f"    {key[:80]}", file=sys.stderr)
            if len(missing) > 20:
                print(f"    …还有 {len(missing) - 20} 条", file=sys.stderr)
            return 1
        suffix = f"(其中 {fallback_count} 条暂回退简体)" if fallback_count else ""

        print(f"{os.path.relpath(out, os.path.join(ROOT, '..'))}: {len(strings)} 键{suffix}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
