#!/usr/bin/env python3
"""把双语（英中对照）发布日志拆成单语言的 HTML，供发布工具校验和展示。

用法：split_release_notes.py NOTES.md OUT_DIR
产出：OUT_DIR/notes.{en,zh-Hans}.html
"""
import html
import pathlib
import re
import sys

def cjk_ratio(line: str) -> float:
    chars = [c for c in line if not c.isspace()]
    if not chars:
        return 0.0
    cjk = sum(1 for c in chars if "一" <= c <= "鿿" or "　" <= c <= "〿" or "＀" <= c <= "￯")
    return cjk / len(chars)

def is_zh(line: str) -> bool:
    return cjk_ratio(line) > 0.25

HEADER_RE = re.compile(r"^(#*\s*)?\S.* / .+$")

def split_header(line: str):
    left, right = line.rsplit(" / ", 1)
    if not is_zh(right) or is_zh(left):
        return None
    left_txt = re.sub(r"^#+\s*", "", left)
    return left_txt, right

EN_MARKER = "<!-- lang:en -->"
ZH_MARKER = "<!-- lang:zh-Hans -->"

MIN_EN_CHARS = 200
MIN_ZH_CHARS = 80

def split_notes_by_marker(text: str):
    if EN_MARKER not in text or ZH_MARKER not in text:
        return None
    header, rest = text.split(EN_MARKER, 1)
    en_body, zh_body = rest.split(ZH_MARKER, 1)
    header_lines = [ln.rstrip() for ln in header.splitlines() if ln.strip()]
    en = header_lines + [""] + en_body.strip("\n").splitlines()
    zh = header_lines + [""] + zh_body.strip("\n").splitlines()
    return en, zh

def split_notes(text: str):
    en_lines: list[str] = []
    zh_lines: list[str] = []
    bullet_zh_pending: list[str] = []

    def flush_bullet_zh():
        nonlocal bullet_zh_pending
        for i, ln in enumerate(bullet_zh_pending):
            zh_lines.append(("- " if i == 0 else "  ") + ln.strip())
        bullet_zh_pending = []

    in_bullet = False
    for raw in text.splitlines():
        line = raw.rstrip("\n")
        stripped = line.strip()

        if not stripped:
            flush_bullet_zh()
            in_bullet = False
            en_lines.append("")
            zh_lines.append("")
            continue

        if stripped.startswith("|") or stripped.startswith("**Full Changelog**") or stripped.startswith("http"):
            flush_bullet_zh()
            in_bullet = False
            en_lines.append(line)
            zh_lines.append(line)
            continue

        if not line.startswith(" ") and not line.startswith("- ") and " / " in line and HEADER_RE.match(line):
            parts = split_header(line)
            if parts:
                flush_bullet_zh()
                in_bullet = False
                en_lines.append("### " + parts[0])
                zh_lines.append("### " + parts[1])
                continue

        if line.startswith("- "):
            flush_bullet_zh()
            in_bullet = True
            if is_zh(line):
                bullet_zh_pending.append(line[2:])
            else:
                en_lines.append(line)
            continue

        if in_bullet:
            if is_zh(line):
                bullet_zh_pending.append(line)
            else:
                en_lines.append(line)
            continue

        if is_zh(line):
            zh_lines.append(line)
        elif re.match(r"^v\d+\.\d+\.\d+$", stripped):
            en_lines.append(line)
            zh_lines.append(line)
        else:
            en_lines.append(line)

    flush_bullet_zh()
    return en_lines, zh_lines

CJKISH = re.compile(r"[^\x00-\x7f]")

def join_wrapped(parts: list[str]) -> str:
    out = ""
    for p in parts:
        p = p.strip()
        if not p:
            continue
        if not out:
            out = p
            continue
        if CJKISH.match(out[-1]) or CJKISH.match(p[0]):
            out += p
        else:
            out += " " + p
    return out

def inline_md(text: str) -> str:
    s = html.escape(text, quote=False)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
    return s

def render_html(lines: list[str], lang: str) -> str:
    body: list[str] = []
    para: list[str] = []
    li: list[str] = []
    in_list = False
    table: list[str] = []

    def flush_para():
        nonlocal para
        if para:
            body.append("<p>" + inline_md(join_wrapped(para)) + "</p>")
            para = []

    def flush_li():
        nonlocal li
        if li:
            body.append("<li>" + inline_md(join_wrapped(li)) + "</li>")
            li = []

    def close_list():
        nonlocal in_list
        flush_li()
        if in_list:
            body.append("</ul>")
            in_list = False

    def flush_table():
        nonlocal table
        if not table:
            return
        rows = []
        for r in table:
            cells = [c.strip() for c in r.strip().strip("|").split("|")]
            if all(re.fullmatch(r":?-{3,}:?", c) for c in cells):
                continue
            rows.append("<tr>" + "".join("<td>" + inline_md(c) + "</td>" for c in cells) + "</tr>")
        body.append("<table>" + "".join(rows) + "</table>")
        table = []

    first = True
    for line in lines:
        stripped = line.strip()
        if not stripped:
            flush_para()
            close_list()
            flush_table()
            continue
        if stripped.startswith("|"):
            flush_para()
            close_list()
            table.append(stripped)
            continue
        flush_table()
        if first and re.fullmatch(r"v\d+\.\d+\.\d+", stripped):
            body.append("<h2>" + html.escape(stripped) + "</h2>")
            first = False
            continue
        first = False
        if stripped.startswith("### "):
            flush_para()
            close_list()
            body.append("<h3>" + inline_md(stripped[4:]) + "</h3>")
            continue
        if line.startswith("- "):
            flush_para()
            flush_li()
            if not in_list:
                body.append("<ul>")
                in_list = True
            li.append(line[2:])
            continue
        if in_list and line.startswith("  "):
            li.append(line)
            continue
        close_list()
        para.append(line)
    flush_para()
    close_list()
    flush_table()

    return (
        f'<!DOCTYPE html>\n<html lang="{lang}"><head><meta charset="utf-8"><style>\n'
        "body{font:13px -apple-system,'PingFang SC',sans-serif;line-height:1.55;margin:14px;color:#333}\n"
        "@media(prefers-color-scheme:dark){body{color:#ddd;background:#1e1e1e}a{color:#6cf}}\n"
        "h2{font-size:17px;margin:0 0 10px}h3{font-size:14px;margin:16px 0 6px}\n"
        "ul{margin:6px 0;padding-left:20px}li{margin:3px 0}\n"
        "table{border-collapse:collapse;margin:8px 0}td{border:1px solid #8884;padding:4px 8px}\n"
        "</style></head><body>\n" + "\n".join(body) + "\n</body></html>\n"
    )

def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    out_dir = pathlib.Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    by_marker = split_notes_by_marker(src)
    en_lines, zh_lines = by_marker if by_marker else split_notes(src)
    en_plain = "\n".join(en_lines)
    zh_plain = "\n".join(zh_lines)

    if len(en_plain) < MIN_EN_CHARS or len(zh_plain) < MIN_ZH_CHARS:
        print(f"!! 拆分结果太短 en={len(en_plain)} zh={len(zh_plain)}（要求 en≥{MIN_EN_CHARS}、zh≥{MIN_ZH_CHARS}），拒绝输出",
              file=sys.stderr)
        return 1
    (out_dir / "notes.en.html").write_text(render_html(en_lines, "en"), encoding="utf-8")
    (out_dir / "notes.zh-Hans.html").write_text(render_html(zh_lines, "zh-Hans"), encoding="utf-8")
    print(f"en {len(en_plain)} chars, zh {len(zh_plain)} chars -> {out_dir}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
