#!/usr/bin/env python3
from pathlib import Path
import urllib.request
import sys

ROOT = Path(__file__).resolve().parents[1]

# 上游 raw URL -> 你私库内目标路径
# 注意：目标路径要和你 Surge 配置里的路径一致。
TASKS = {
    # Centralmatrix3
    "Centralmatrix3/Matrix-io/Surge/Ruleset/Unbreak.list":
        "https://raw.githubusercontent.com/Centralmatrix3/Matrix-io/master/Surge/Ruleset/Unbreak.list",

    # SukkaLab ruleset.skk.moe，原 Sukka/List/* 应对应这个仓库
    "Sukka/List/domainset/speedtest.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/domainset/speedtest.conf",
    "Sukka/List/domainset/cdn.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/domainset/cdn.conf",
    "Sukka/List/domainset/apple_cdn.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/domainset/apple_cdn.conf",
    "Sukka/List/domainset/download.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/domainset/download.conf",

    "Sukka/List/non_ip/cdn.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/non_ip/cdn.conf",
    "Sukka/List/non_ip/stream.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/non_ip/stream.conf",
    "Sukka/List/non_ip/microsoft_cdn.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/non_ip/microsoft_cdn.conf",
    "Sukka/List/non_ip/download.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/non_ip/download.conf",
    "Sukka/List/non_ip/apple_cn.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/non_ip/apple_cn.conf",
    "Sukka/List/non_ip/apple_services.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/non_ip/apple_services.conf",
    "Sukka/List/non_ip/microsoft.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/non_ip/microsoft.conf",
    "Sukka/List/non_ip/ai.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/non_ip/ai.conf",
    "Sukka/List/non_ip/global.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/non_ip/global.conf",
    "Sukka/List/non_ip/domestic.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/non_ip/domestic.conf",
    "Sukka/List/non_ip/direct.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/non_ip/direct.conf",
    "Sukka/List/non_ip/lan.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/non_ip/lan.conf",

    "Sukka/List/ip/stream.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/ip/stream.conf",
    "Sukka/List/ip/lan.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/ip/lan.conf",
    "Sukka/List/ip/domestic.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/ip/domestic.conf",
    "Sukka/List/ip/china_ip.conf":
        "https://raw.githubusercontent.com/SukkaLab/ruleset.skk.moe/master/List/ip/china_ip.conf",

    # ConnersHua
    "ConnersHua/RuleGo/Surge/Ruleset/Extra/GeoLoc.list":
        "https://raw.githubusercontent.com/ConnersHua/RuleGo/master/Surge/Ruleset/Extra/GeoLoc.list",
    "ConnersHua/RuleGo/Surge/Ruleset/Extra/Google/Google.list":
        "https://raw.githubusercontent.com/ConnersHua/RuleGo/master/Surge/Ruleset/Extra/Google/Google.list",

    # 666OS/rules release 分支
    "666OS/surge/GitHub.txt":
        "https://raw.githubusercontent.com/666OS/rules/release/surge/GitHub.txt",
    "666OS/surge/YouTube.txt":
        "https://raw.githubusercontent.com/666OS/rules/release/surge/YouTube.txt",
    "666OS/surge/Spotify.txt":
        "https://raw.githubusercontent.com/666OS/rules/release/surge/Spotify.txt",
    "666OS/surge/Instagram.txt":
        "https://raw.githubusercontent.com/666OS/rules/release/surge/Instagram.txt",
    "666OS/surge/Facebook.txt":
        "https://raw.githubusercontent.com/666OS/rules/release/surge/Facebook.txt",
    "666OS/surge/Twitter.txt":
        "https://raw.githubusercontent.com/666OS/rules/release/surge/Twitter.txt",
    "666OS/surge/NewsMedia.txt":
        "https://raw.githubusercontent.com/666OS/rules/release/surge/NewsMedia.txt",
    "666OS/surge/Private.txt":
        "https://raw.githubusercontent.com/666OS/rules/release/surge/Private.txt",
    "666OS/surge/Direct.txt":
        "https://raw.githubusercontent.com/666OS/rules/release/surge/Direct.txt",
}

PLACEHOLDER_PREFIX = "这里写 "


def download(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "GitHub-Actions-Rule-Sync"})
    with urllib.request.urlopen(req, timeout=60) as r:
        if r.status != 200:
            raise RuntimeError(f"HTTP {r.status}")
        return r.read().decode("utf-8", "replace")


def valid_content(text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return False
    first_real = ""
    for line in stripped.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            first_real = line
            break
    if not first_real:
        return True
    if first_real.startswith(PLACEHOLDER_PREFIX):
        return False
    if "的新内容" in first_real:
        return False
    if "404:" in stripped[:100] or stripped.lower().startswith("<!doctype") or "<html" in stripped[:200].lower():
        return False
    return True


def main():
    changed = False
    failed = 0
    for rel_path, url in TASKS.items():
        print(f"sync {rel_path}")
        try:
            text = download(url)
            if not valid_content(text):
                raise RuntimeError("downloaded content looks invalid or placeholder")
            dst = ROOT / rel_path
            dst.parent.mkdir(parents=True, exist_ok=True)
            old = dst.read_text(encoding="utf-8") if dst.exists() else None
            if old != text:
                dst.write_text(text, encoding="utf-8")
                changed = True
                print(f"  updated: {rel_path}")
            else:
                print(f"  unchanged: {rel_path}")
        except Exception as e:
            failed += 1
            print(f"  FAILED: {rel_path}: {e}", file=sys.stderr)
    if failed:
        print(f"failed={failed}", file=sys.stderr)
        sys.exit(1)
    print("changed=yes" if changed else "changed=no")

if __name__ == "__main__":
    main()

