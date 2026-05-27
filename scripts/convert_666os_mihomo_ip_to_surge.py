#!/usr/bin/env python3

import ipaddress
import json
import sys
import urllib.request
from pathlib import Path


SOURCE_API = "https://api.github.com/repos/666OS/rules/contents/mihomo/ip?ref=release"
OUTPUT_DIR = Path("surge/ip")


def fetch_json(url: str):
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "github-actions-surge-rule-converter",
            "Accept": "application/vnd.github+json",
        },
    )

    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_text(url: str) -> str:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "github-actions-surge-rule-converter",
        },
    )

    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8-sig")


def convert_line(line: str) -> str | None:
    line = line.strip()

    if not line:
        return None

    if line.startswith("#"):
        return None

    if line.startswith("//"):
        return None

    # 兼容类似 IP-CIDR,1.1.1.0/24,no-resolve
    if "," in line:
        parts = [x.strip() for x in line.split(",")]
        rule_type = parts[0].upper()

        if rule_type in ("IP-CIDR", "IP-CIDR6") and len(parts) >= 2:
            line = parts[1]
        elif rule_type == "IP-ASN" and len(parts) >= 2:
            return f"IP-ASN,{parts[1].upper().removeprefix('AS')}"
        elif rule_type == "GEOIP" and len(parts) >= 2:
            return f"GEOIP,{parts[1].upper()}"
        else:
            return None

    try:
        network = ipaddress.ip_network(line, strict=False)
    except ValueError:
        return None

    if network.version == 4:
        return f"IP-CIDR,{network}"

    return f"IP-CIDR6,{network}"


def convert_file(name: str, download_url: str) -> tuple[int, int]:
    text = fetch_text(download_url)

    output_lines = [
        f"# NAME: {Path(name).stem}",
        "# SOURCE: 666OS/rules mihomo/ip",
        "# CONVERTED: Mihomo IP CIDR to Surge ruleset",
        "",
    ]

    seen = set()
    converted_count = 0
    skipped_count = 0

    for raw_line in text.splitlines():
        converted = convert_line(raw_line)

        if converted is None:
            if raw_line.strip() and not raw_line.strip().startswith("#"):
                skipped_count += 1
            continue

        key = converted.upper()

        if key in seen:
            continue

        seen.add(key)
        output_lines.append(converted)
        converted_count += 1

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    output_name = Path(name).with_suffix(".list").name
    output_path = OUTPUT_DIR / output_name
    output_path.write_text("\n".join(output_lines).rstrip() + "\n", encoding="utf-8")

    print(f"{name} -> {output_path}: {converted_count} rules, {skipped_count} skipped")

    return converted_count, skipped_count


def main():
    items = fetch_json(SOURCE_API)

    if not isinstance(items, list):
        print("Failed to list source directory", file=sys.stderr)
        raise SystemExit(1)

    txt_files = [
        item
        for item in items
        if item.get("type") == "file"
        and item.get("name", "").endswith(".txt")
        and item.get("download_url")
    ]

    if not txt_files:
        print("No .txt files found", file=sys.stderr)
        raise SystemExit(1)

    total_files = 0
    total_rules = 0
    total_skipped = 0

    for item in sorted(txt_files, key=lambda x: x["name"].lower()):
        converted_count, skipped_count = convert_file(
            item["name"],
            item["download_url"],
        )

        total_files += 1
        total_rules += converted_count
        total_skipped += skipped_count

    print("")
    print(f"Converted files: {total_files}")
    print(f"Converted rules: {total_rules}")
    print(f"Skipped lines: {total_skipped}")


if __name__ == "__main__":
    main()
