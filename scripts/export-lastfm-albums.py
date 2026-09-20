#!/usr/bin/env python3
import json, re, sys, unicodedata
from datetime import date

ALIAS = {'david tao':'陶喆','jason chan':'陈柏宇','kun':'蔡徐坤','dean ting':'丁世光','crowd lu':'卢广仲',
'leah dou':'窦靖童','soft lipa':'蛋堡','diana wang':'王诗安','a si':'阿肆','eve ai':'艾怡良',
'nicky lee':'李玖哲','utada':'宇多田ヒカル','hikaru utada':'宇多田ヒカル','宇多田光':'宇多田ヒカル','wanting':'曲婉婷','ronghao li':'李荣浩','matt lv':'吕彦良',
'pei-yu hung':'洪佩瑜','lexie liu':'刘柏辛','sodagreen':'苏打绿','zhang yu sheng':'张雨生',
'khalil fong':'方大同','jay chou':'周杰伦'}
EDITION = re.compile(r'\s*[\(\[（【](?=[^)\]）】]*(deluxe|explicit|remaster|gold|black|bonus track))[^)\]）】]*[\)\]）】]', re.I)
SINGLE_SUFFIX = re.compile(r'\s*-\s*(single|ep)\s*$', re.I)

def main(t2s_in, t2s_out, raw_json, out_md):
    t2s = dict(zip(open(t2s_in).read().split('\n'), open(t2s_out).read().split('\n')))
    rows = json.load(open(raw_json))

    VARIANTS = str.maketrans({'晩': '晚'})
    def fold(s):
        return re.sub(r'[\s\W_]+', '', unicodedata.normalize('NFKC', s).casefold().translate(VARIANTS))
    def artdisp(a): return ALIAS.get(a.strip().lower(), a)
    def artkey(a): return fold(t2s.get(artdisp(a), artdisp(a)))

    writings = {}
    for r in rows:
        writings.setdefault(artkey(r['artist']), set()).add(r['artist'].strip())
    for roman, canon in ALIAS.items():
        k = fold(t2s.get(canon, canon))
        writings.setdefault(k, set()).update({roman, canon})

    def albkeys(album, ak):
        s = t2s.get(album, album)
        s = EDITION.sub('', s)
        s = SINGLE_SUFFIX.sub('', s)
        low = unicodedata.normalize('NFKC', s).casefold()
        for w in sorted(writings.get(ak, ()), key=len, reverse=True):
            w2 = unicodedata.normalize('NFKC', t2s.get(w, w)).casefold()
            if w2 and w2 in low:
                stripped = low.replace(w2, ' ')
                if fold(stripped):
                    low = stripped
        base = fold(low)
        keys = {base} if base else {fold(album)}

        runs, cur = [], None
        for ch in base:
            kind = 'h' if '一' <= ch <= '鿿' else ('l' if ch.isascii() else 'x')
            if kind == 'x': continue
            if cur and cur[0] == kind: cur[1] += ch
            else:
                cur = [kind, ch]; runs.append(cur)
        if len(runs) == 2 and {runs[0][0], runs[1][0]} == {'h', 'l'}:
            for _, seg in runs:
                if len(seg) >= 2:
                    keys.add(seg)
        return keys

    n = len(rows)
    parent = list(range(n))
    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]; x = parent[x]
        return x
    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb: parent[ra] = rb
    groups = {}
    for i, r in enumerate(rows):
        ak = artkey(r['artist'])
        for k in albkeys(r['album'], ak):
            groups.setdefault((ak, k), []).append(i)
    for idxs in groups.values():
        for j in idxs[1:]:
            union(idxs[0], j)

    buckets = {}
    order = []
    for i, r in enumerate(rows):
        root = find(i)
        b = buckets.get(root)
        if b is None:
            b = {'album': r['album'], 'artist': artdisp(r['artist']), 'plays': 0, 'members': []}
            buckets[root] = b; order.append(root)
        b['plays'] += r['plays']
        b['members'].append((r['album'], r['artist'], r['plays']))
    out = sorted(buckets.values(), key=lambda m: (-m['plays'], m['artist'], m['album']))

    total = sum(m['plays'] for m in out)
    singles = sum(1 for m in out if SINGLE_SUFFIX.search(m['album']))
    today = date.today().isoformat()
    lines = ['# Last.fm 全部听过的专辑', '',
      f'> 生成于 {today} · 历史累计(overall) · 归并规则见附录 C',
      f'> 共 {len(out)} 张(其中含 - Single/EP 标记 {singles} 条) · 合计播放 {total:,} 次', '',
      '| # | 专辑 | 歌手 | 播放次数 |', '|---:|---|---|---:|']
    for i, m in enumerate(out, 1):
        lines.append(f"| {i} | {m['album']} | {m['artist']} | {m['plays']:,} |")

    mergedRows = [m for m in out if len(m['members']) > 1 or {a for _, a, _ in m['members']} != {m['artist']}]
    lines += ['', '---', '', f'## 附录 A · 发生过归并的条目(共 {len(mergedRows)} 条)', '',
      '| 归并后 | 歌手 | 合计 | 由哪些原始条目合成(各自次数) |', '|---|---|---:|---|']
    for m in mergedRows:
        variants = ' + '.join(f'{a}({p})' for a, _, p in m['members'])
        lines.append(f"| {m['album']} | {m['artist']} | {m['plays']:,} | {variants} |")
    lines += ['', '## 附录 B · 名称相近但刻意保留独立的代表(不同专辑,勿并)', '',
      '- 前缀对: 范特西/依然范特西、回到未來/未來、Soulboy/The SOULBOY Collection、Timeless/This Love 类',
      '- Live 与录音室: 15/15 (Live in Hong Kong 2011)、Timeless/Khalil Timeless Concert Live 2009',
      '- 纪念版: Thriller/Thriller 40', '',
      '## 附录 C · 归并规则', '',
      '1. 简繁/大小写/空白/标点折叠;歌手别名统一(与 collector artistAliasTable 同步)',
      '2. 同内容再版标签剥除: Deluxe/Explicit/Remastered/Gold/Black/Bonus Track',
      '3. R1 双语拼接名: 一段中文+一段拉丁拼成的标题,两段各自等价(Timeless 可啦思刻)',
      '4. R2 尾部 "- Single"/"- EP" 商店标记剥除(玩樂 = 玩乐 - Single)',
      '5. R3 专辑名内歌手自己的任何已知写法剥除(15 Khalil Fong Live… = 15 (Live…);剥空回退)',
      '6. 不做前缀/子集归并、不并 Live 版、不并纪念版重制']
    open(out_md, 'w').write('\n'.join(lines) + '\n')
    print(f'merged: {len(out)} buckets (raw {n}), total plays {total}')
    return out

if __name__ == '__main__':
    main(*sys.argv[1:5])
