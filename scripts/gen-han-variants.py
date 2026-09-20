#!/usr/bin/env python3
import argparse
import collections
import io
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TS_CHARACTERS = os.path.join(ROOT, "lyrimuse-collector", "dictionary", "TSCharacters.txt")
OVERRIDES = os.path.join(ROOT, "scripts", "han-variant-overrides.txt")
ICU_PROBE = os.path.join(ROOT, "scripts", "han-icu-probe.swift")
OUT_TXT = os.path.join(ROOT, "lyrimuse-collector", "dictionary", "HanVariants.txt")
OUT_SWIFT = os.path.join(ROOT, "lyrimuse", "Sources", "LyrimuseCore", "Lyrics", "HanVariantsTable.swift")

UNIHAN_URL = "https://www.unicode.org/Public/UCD/latest/ucd/Unihan.zip"
NEEDED = ("Unihan_Variants.txt", "Unihan_DictionaryLikeData.txt")

def load_unihan(unihan_dir):
    blobs = {}
    if unihan_dir:
        for name in NEEDED:
            path = os.path.join(unihan_dir, name)
            with open(path, encoding="utf-8") as f:
                blobs[name] = f.read()
    else:
        print("下载 %s …" % UNIHAN_URL, file=sys.stderr)
        with urllib.request.urlopen(UNIHAN_URL, timeout=120) as resp:
            data = resp.read()
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for name in NEEDED:
                blobs[name] = z.read(name).decode("utf-8")

    version = "unknown"
    m = re.search(r"^#\s*Unicode Version:?\s+(\S+)", blobs["Unihan_Variants.txt"], re.M)
    if m:
        version = m.group(1)

    variants = collections.defaultdict(lambda: collections.defaultdict(list))
    for line in blobs["Unihan_Variants.txt"].splitlines():
        if not line.startswith("U+"):
            continue
        cp, field, vals = line.split("\t", 2)
        for token in vals.split():

            target = token.split("<")[0]
            if target.startswith("U+") and target != cp:
                variants[cp][field].append(target)

    core, grade = {}, {}
    for line in blobs["Unihan_DictionaryLikeData.txt"].splitlines():
        if not line.startswith("U+"):
            continue
        cp, field, val = line.split("\t", 2)
        if field == "kUnihanCore2020":
            core[cp] = val
        elif field == "kGradeLevel":
            grade[cp] = int(val)
    return variants, core, grade, version

def load_opencc_chars():
    table = {}
    with open(TS_CHARACTERS, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0]:
                table[parts[0]] = parts[1].split()[0]
    return table

def load_overrides():
    adds, vetoes = {}, {}
    with open(OVERRIDES, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            src, dst = parts[0].strip(), parts[1].strip()
            reason = parts[2].strip() if len(parts) > 2 else ""
            if dst == "-":
                vetoes[src] = reason
            else:
                adds[src] = (dst, reason)
    return adds, vetoes

def icu_converts(chars):
    with tempfile.TemporaryDirectory() as tmp:
        binary = os.path.join(tmp, "han-icu-probe")
        subprocess.run(["swiftc", "-O", "-o", binary, ICU_PROBE], check=True,
                       stdout=subprocess.DEVNULL)
        proc = subprocess.run([binary], input="\n".join(chars), capture_output=True,
                              text=True, check=True)
    out = {}
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            out[parts[0]] = parts[1]
    return out

def derive():
    args = parse_args()
    variants, core, grade, version = load_unihan(args.unihan_dir)
    opencc = load_opencc_chars()
    adds, vetoes = load_overrides()

    def ch(cp):
        return chr(int(cp[2:], 16))

    def cp_of(c):
        return "U+%04X" % ord(c)

    in_g = lambda cp: "G" in core.get(cp, "")
    common = lambda cp: cp in grade

    def pick_semantic(cands):
        c = sorted({x for x in cands if in_g(x)})
        if len(c) > 1:
            graded = [x for x in c if common(x)]
            if len(graded) == 1:
                c = graded
        return c[0] if len(c) == 1 else None

    picked = {}
    universe = sorted(set(variants) | {cp_of(c) for c in opencc})
    for cp in universe:
        v = ch(cp)

        if cp not in core or in_g(cp):
            continue
        if v in opencc and in_g(cp_of(opencc[v])):
            picked[v] = (opencc[v], "opencc")
            continue
        fields = variants.get(cp, {})
        simplified = sorted(set(fields.get("kSimplifiedVariant", [])))
        if len(simplified) == 1 and in_g(simplified[0]):
            picked[v] = (ch(simplified[0]), "unihan-simplified")
            continue
        target = pick_semantic(fields.get("kSpecializedSemanticVariant", []))
        if target:
            picked[v] = (ch(target), "unihan-specialized")
            continue
        target = pick_semantic(fields.get("kSemanticVariant", []))
        if target:
            picked[v] = (ch(target), "unihan-semantic")

    for src, (dst, _reason) in adds.items():
        picked[src] = (dst, "override")

    for src, (dst, source) in list(picked.items()):
        seen = {dst}
        while dst in opencc:
            nxt = opencc[dst]
            if nxt in seen:
                break
            dst = nxt
            seen.add(dst)
        picked[src] = (dst, source)

    icu = icu_converts(sorted(picked))
    rows = []
    for v in sorted(picked):
        target, source = picked[v]
        if v in vetoes:
            continue
        gaps = []
        if icu.get(v, v) == v:
            gaps.append("icu")
        if v not in opencc:
            gaps.append("opencc")
        if not gaps:
            continue
        rows.append((v, target, source, "+".join(gaps)))
    return rows, version, len(picked), vetoes

def render_txt(rows, version):
    by_source = collections.Counter(r[2] for r in rows)
    by_gap = collections.Counter(r[3] for r in rows)
    lines = [
        "# 异体字 → 大陆规范字。**生成产物,不要手改**。",
        "# 生成:python3 scripts/gen-han-variants.py(推导规则、为什么不手工维护见那个脚本的头注)",
        "# 数据来源:Unicode Unihan %s(kUnihanCore2020/kGradeLevel/k*Variant)+ OpenCC TSCharacters" % version,
        "#          + scripts/han-variant-overrides.txt(人工补丁,每行带理由)",
        "# 列:变体字<TAB>大陆规范字<TAB>数据依据<TAB>填的是谁的缺口(icu=Swift 侧 / opencc=Go 侧)",
        "# 条目 %d;依据分布 %s;缺口分布 %s" % (
            len(rows),
            " ".join("%s=%d" % (k, v) for k, v in sorted(by_source.items())),
            " ".join("%s=%d" % (k, v) for k, v in sorted(by_gap.items()))),
    ]
    for v, target, source, gap in rows:
        lines.append("%s\t%s\t%s\t%s" % (v, target, source, gap))
    return "\n".join(lines) + "\n"

def render_swift(rows, version):
    variants = "".join(r[0] for r in rows)
    targets = "".join(r[1] for r in rows)
    icu_gap = "".join(r[0] for r in rows if "icu" in r[3])
    return '''enum HanVariantsTable {{

    static let variantForms = "{variants}"

    static let standardForms = "{targets}"

    static let icuGapVariants = "{icu_gap}"

    static let toSimplified: [Character: Character] = {{
        var map: [Character: Character] = [:]
        map.reserveCapacity({count})
        for (v, s) in zip(variantForms, standardForms) {{ map[v] = s }}
        return map
    }}()

    static let icuGaps: Set<Character> = Set(icuGapVariants)
}}
'''.format(version=version, variants=variants, targets=targets, icu_gap=icu_gap, count=len(rows))

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--unihan-dir", help="已解压的 Unihan 数据目录(缺省时联网下载)")
    p.add_argument("--check", action="store_true", help="只校验产物是否最新,不写文件")
    return p.parse_args()

def main():
    args = parse_args()
    rows, version, considered, vetoes = derive()
    txt, swift = render_txt(rows, version), render_swift(rows, version)
    if args.check:
        bad = False
        for path, want in ((OUT_TXT, txt), (OUT_SWIFT, swift)):
            got = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
            if got != want:
                print("过期: %s(重新跑一次 scripts/gen-han-variants.py)" % path)
                bad = True
        if bad:
            sys.exit(1)
        print("产物是最新的:%d 条(Unihan %s)" % (len(rows), version))
        return
    open(OUT_TXT, "w", encoding="utf-8").write(txt)
    open(OUT_SWIFT, "w", encoding="utf-8").write(swift)
    print("Unihan %s:考察 %d 个非通用字,写出 %d 条(否决 %d 条)" %
          (version, considered, len(rows), len(vetoes)))
    print("  ->", OUT_TXT)
    print("  ->", OUT_SWIFT)

if __name__ == "__main__":
    main()
