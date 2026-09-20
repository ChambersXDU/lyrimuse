#!/usr/bin/env python3
"""校验 release.yml 生成的 appcast.xml 形状对不对。

用法:  python3 .github/scripts/check_appcast.py appcast.xml [--tag vX.Y.Z[-beta.N]] [--display-version X.Y.Z[-beta.N]] [--build-version X.Y.Z.B] [--prerelease true|false]
"""
from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
BUILD_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+\.\d+$")

def check(path: str, tag: str | None = None, display_version: str | None = None,
          build_version: str | None = None, prerelease: bool | None = None) -> list[str]:
    problems: list[str] = []
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as e:
        return [f"读不了/解析不动 {path}: {e}"]

    items = root.findall("./channel/item")
    if len(items) != 2:
        problems.append(f"item 数应为 2(arm64 + intel),实际 {len(items)}")

    for i, item in enumerate(items):
        where = f"item[{i}]"
        hw = [e.text for e in item.findall(f"{{{SPARKLE_NS}}}hardwareRequirements")]
        enc = item.find("enclosure")
        if enc is None:
            problems.append(f"{where} 没有 <enclosure>")
            continue
        url = enc.get("url") or ""
        sig = enc.get(f"{{{SPARKLE_NS}}}edSignature") or ""
        length = enc.get("length") or ""

        if enc.get(f"{{{SPARKLE_NS}}}hardwareRequirements") or enc.get("sparkle:hardwareRequirements"):
            problems.append(
                f"{where} 把 hardwareRequirements 写成了 <enclosure> 的属性 —— "
                "Sparkle 只认 <item> 的子元素,属性形态会静默匹配不到任何东西")
        if not sig:
            problems.append(f"{where} 没有 sparkle:edSignature")
        if not length.isdigit() or int(length) <= 0:
            problems.append(f"{where} length 非法: {length!r}")
        if not url.endswith(".zip"):
            problems.append(f"{where} enclosure url 不是 .zip: {url!r}")
        if "/releases/latest/" in url:
            problems.append(
                f"{where} enclosure url 指向 releases/latest/ —— 预发布不是 latest,这个链接在它的 appcast 里"
                f"会落到最新正式版的目录、404;必须是 releases/download/<tag>/: {url!r}")
        if tag and f"/releases/download/{tag}/" not in url:
            problems.append(f"{where} enclosure url 不在 releases/download/{tag}/ 目录下: {url!r}")
        if display_version:
            expected_name = f"Lyrimuse-v{display_version}-macos{'-intel' if i == 1 else ''}.zip"
            if not url.endswith("/" + expected_name):
                problems.append(f"{where} zip 文件名应为 {expected_name},实际 {url.rsplit('/', 1)[-1]!r}")
            short = (item.findtext(f"{{{SPARKLE_NS}}}shortVersionString") or "").strip()
            if short != display_version:
                problems.append(f"{where} sparkle:shortVersionString 应为 {display_version!r},实际 {short!r}")
        item_version = (item.findtext(f"{{{SPARKLE_NS}}}version") or "").strip()
        enclosure_version = (enc.get(f"{{{SPARKLE_NS}}}version") or "").strip()
        if item_version and not BUILD_VERSION_RE.match(item_version):
            problems.append(
                f"{where} sparkle:version 不是四段纯数字: {item_version!r} —— Sparkle 的比较器忽略 '-' 之后的内容,"
                "展示版本不能直接当比较用的构建号(见 lyrimuse/scripts/build-version.sh)")
        if enclosure_version != item_version:
            problems.append(f"{where} enclosure 的 sparkle:version 属性({enclosure_version!r})与元素({item_version!r})不一致")
        if build_version and item_version != build_version:
            problems.append(f"{where} sparkle:version 应为 {build_version!r},实际 {item_version!r}")
        channels = [(e.text or "").strip() for e in item.findall(f"{{{SPARKLE_NS}}}channel")]
        if prerelease is True and channels != ["beta"]:
            problems.append(f"{where} 预发布 item 必须且只能带一个 <sparkle:channel>beta</sparkle:channel>,实际 {channels!r}")
        if prerelease is False and channels:
            problems.append(f"{where} 正式版 item 不该带 sparkle:channel,实际 {channels!r} —— 带了正式用户就收不到这一版")

        if i == 0:
            if hw != ["arm64"]:
                problems.append(
                    f"{where} 必须且只能带一个 hardwareRequirements=arm64,实际 {hw!r}")
            if "-intel.zip" in url:
                problems.append(
                    f"{where} 指向了 -intel 包 —— 两个 item 顺序反了。版本号相同时 Sparkle "
                    "取先出现的那个,arm64 用户会开始白下 2 倍大的 universal 包(而且装得上、"
                    "跑得起来,没人会发现)")
        else:
            if hw:
                problems.append(
                    f"{where}(intel)不该带 hardwareRequirements,实际 {hw!r} —— "
                    "带了就等于 Intel 客户端把它也剔掉,两个架构都收不到更新")
            if "-intel.zip" not in url:
                problems.append(f"{where} 应指向 -intel 包,实际 {url!r}")

    versions = {
        (item.findtext(f"{{{SPARKLE_NS}}}version") or "").strip()
        for item in items
    }
    if len(versions) > 1:
        problems.append(f"两个 item 的 sparkle:version 不一致: {sorted(versions)!r}")
    if "" in versions:
        problems.append("有 item 缺 sparkle:version")

    return problems

def parse_bool(value: str) -> bool:
    lowered = value.strip().lower()
    if lowered in ("true", "yes", "1"):
        return True
    if lowered in ("false", "no", "0"):
        return False
    raise argparse.ArgumentTypeError(f"--prerelease 要 true/false,收到 {value!r}")

def main() -> int:
    parser = argparse.ArgumentParser(description="校验 release.yml 生成的 appcast.xml 形状", add_help=True)
    parser.add_argument("path")
    parser.add_argument("--tag", help="Release 的 tag(vX.Y.Z 或 vX.Y.Z-beta.N),enclosure 必须在它的目录下")
    parser.add_argument("--display-version", help="展示版本 = tag 去 v,对 shortVersionString 与 zip 文件名")
    parser.add_argument("--build-version", help="四段纯数字构建号,对 sparkle:version")
    parser.add_argument("--prerelease", type=parse_bool, default=None, help="true/false:预发布 item 必须带 beta channel,正式版不许带")
    args = parser.parse_args()
    problems = check(args.path, tag=args.tag, display_version=args.display_version,
                     build_version=args.build_version, prerelease=args.prerelease)
    if problems:
        print("appcast 自检失败:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1
    print("appcast 自检通过:2 个 item,arm64 在前带 hardwareRequirements,intel 在后不带")
    return 0

if __name__ == "__main__":
    sys.exit(main())
