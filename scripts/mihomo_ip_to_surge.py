#!/usr/bin/env python3

import argparse
import csv
import ipaddress
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None


SUPPORTED_TYPES = {
    "IP-CIDR",
    "IP-CIDR6",
    "IP-ASN",
    "GEOIP",
}


def strip_inline_comment(line: str) -> str:
    quote = None
    escaped = False
    result = []

    for ch in line:
        if escaped:
            result.append(ch)
            escaped = False
            continue

        if ch == "\\":
            result.append(ch)
            escaped = True
            continue

        if quote:
            result.append(ch)
            if ch == quote:
                quote = None
            continue

        if ch in ("'", '"'):
            quote = ch
            result.append(ch)
            continue

        if ch == "#":
            break

        result.append(ch)

    return "".join(result).strip()


def fallback_load_lines(text: str) -> list[str]:
    items = []

    for raw in text.splitlines():
        line = strip_inline_comment(raw).strip()

        if not line:
            continue

        if line.startswith("#"):
            continue

        if line.startswith("payload:"):
            continue

        if line.startswith("type:"):
            continue

        if line.startswith("behavior:"):
            continue

        if line.startswith("interval:"):
            continue

        if line.startswith("- "):
            line = line[2:].strip()

        if not line:
            continue

        if len(line) >= 2 and line[0] == line[-1] and line[0] in ("'", '"'):
            line = line[1:-1].strip()

        if line:
            items.append(line)

    return items


def load_items(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8-sig")

    if yaml is not None:
        try:
            data = yaml.safe_load(text)
        except Exception:
            data = None

        if isinstance(data, dict):
            payload = data.get("payload") or data.get("rules") or []

            if isinstance(payload, list):
                return [str(x).strip() for x in payload if str(x).strip()]

        if isinstance(data, list):
            return [str(x).strip() for x in data if str(x).strip()]

    return fallback_load_lines(text)


def parse_csv_line(line: str) -> list[str]:
    try:
        return next(csv.reader([line], skipinitialspace=True))
    except Exception:
        return [x.strip() for x in line.split(",")]


def normalize_cidr(value: str) -> tuple[str, str] | None:
    value = value.strip()

    try:
        network = ipaddress.ip_network(value, strict=False)
    except ValueError:
        return None

    if network.version == 4:
        return "IP-CIDR", str(network)

    return "IP-CIDR6", str(network)


def normalize_asn(value: str) -> str | None:
    value = value.strip().upper()

    if value.startswith("AS"):
        value = value[2:]

    if not re.fullmatch(r"\d+", value):
        return None

    return value


def normalize_geoip(value: str) -> str | None:
    value = value.strip().upper()

    if not re.fullmatch(r"[A-Z]{2}", value):
        return None

    return value


def convert_item(item: str) -> str | None:
    item = item.strip()

    if not item:
        return None

    if len(item) >= 2 and item[0] == item[-1] and item[0] in ("'", '"'):
        item = item[1:-1].strip()

    parts = [p.strip() for p in parse_csv_line(item)]

    if not parts:
        return None

    rule_type = parts[0].upper()

    if rule_type in SUPPORTED_TYPES:
        if len(parts) < 2:
            return None

        value = parts[1].strip()

        if rule_type in ("IP-CIDR", "IP-CIDR6"):
            cidr = normalize_cidr(value)

            if cidr is None:
                return None

            detected_type, detected_value = cidr
            return f"{detected_type},{detected_value}"

        if rule_type == "IP-ASN":
            asn = normalize_asn(value)

            if asn is None:
                return None

            return f"IP-ASN,{asn}"

        if rule_type == "GEOIP":
            geoip = normalize_geoip(value)

            if geoip is None:
                return None

            return f"GEOIP,{geoip}"

    bare_cidr = normalize_cidr(item)

    if bare_cidr is not None:
        detected_type, detected_value = bare_cidr
        return f"{detected_type},{detected_value}"

    return None


def convert(input_path: Path, output_path: Path, header: str | None, allow_empty: bool):
    items = load_items(input_path)

    result = []
    seen = set()
    skipped = []

    for item in items:
        converted = convert_item(item)

        if converted is None:
            skipped.append(item)
            continue

        key = converted.upper()

        if key in seen:
            continue

        seen.add(key)
        result.append(converted)

    if not result and not allow_empty:
        print("No supported Mihomo IP rules found.", file=sys.stderr)

        if skipped:
            print("Skipped examples:", file=sys.stderr)
            for item in skipped[:10]:
                print(f"  {item}", file=sys.stderr)

        raise SystemExit(1)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    lines = []

    if header:
        lines.append(f"# {header}")
        lines.append("# Converted from Mihomo IP rules to Surge ruleset.")
        lines.append("# Use no-resolve on the RULE-SET line in Surge profile.")
        lines.append("")

    lines.extend(result)

    output_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

    print(f"Converted: {len(result)} rules")
    print(f"Skipped: {len(skipped)} items")
    print(f"Output: {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Convert Mihomo IP rules to Surge external ruleset."
    )

    parser.add_argument("--input", required=True, help="Mihomo rule file path")
    parser.add_argument("--output", required=True, help="Surge ruleset output path")
    parser.add_argument("--header", default="Generated by GitHub Actions")
    parser.add_argument("--allow-empty", action="store_true")

    args = parser.parse_args()

    convert(
        input_path=Path(args.input),
        output_path=Path(args.output),
        header=args.header,
        allow_empty=args.allow_empty,
    )


if __name__ == "__main__":
    main()
