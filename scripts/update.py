#!/usr/bin/env python3
"""Download a plain domain list and convert it to a Surge rule set."""

from __future__ import annotations

import ipaddress
import os
import re
import tempfile
import urllib.request
from pathlib import Path

SOURCE_URL = "https://static-file-global.353355.xyz/rules/cn-additional-list.txt"
ROOT = Path(__file__).resolve().parents[1]
SOURCE_FILE = ROOT / "source" / "cn-additional-list.txt"
SURGE_FILE = ROOT / "rules" / "cn-additional-list-surge.list"
DOMAIN_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$",
    re.IGNORECASE,
)


def download(url: str) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "cn-additional-list-surge-updater/1.0"},
    )
    with urllib.request.urlopen(request, timeout=90) as response:
        if response.status != 200:
            raise RuntimeError(f"Download failed with HTTP {response.status}")
        data = response.read()
    if not data:
        raise RuntimeError("Downloaded file is empty")
    return data


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(data)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def convert(text: str) -> tuple[str, int]:
    domains: set[str] = set()
    source_comments: list[str] = []

    for line_number, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith(("#", "!")):
            if len(source_comments) < 5:
                source_comments.append(line.lstrip("#! "))
            continue

        # Also accept hosts-file input such as: 0.0.0.0 example.com
        fields = line.split()
        candidate = fields[-1].lower().rstrip(".")
        if len(fields) > 1:
            try:
                ipaddress.ip_address(fields[0])
            except ValueError as error:
                raise ValueError(f"Invalid line {line_number}: {raw_line!r}") from error

        if candidate.startswith("*."):
            candidate = candidate[2:]
        if not DOMAIN_RE.fullmatch(candidate):
            raise ValueError(f"Invalid domain on line {line_number}: {candidate!r}")
        domains.add(candidate)

    if not domains:
        raise RuntimeError("No valid domains found; refusing to replace output")

    header = [
        "# Surge Rule Set",
        f"# Source: {SOURCE_URL}",
        f"# Domain count: {len(domains)}",
    ]
    header.extend(f"# Source info: {comment}" for comment in source_comments)
    rules = [f"DOMAIN-SUFFIX,{domain}" for domain in sorted(domains)]
    return "\n".join(header + [""] + rules) + "\n", len(domains)


def main() -> None:
    raw = download(SOURCE_URL)
    text = raw.decode("utf-8-sig")
    surge, count = convert(text)

    # Write only after download and conversion both succeed.
    normalized_source = text.replace("\r\n", "\n").replace("\r", "\n")
    if not normalized_source.endswith("\n"):
        normalized_source += "\n"
    atomic_write(SOURCE_FILE, normalized_source.encode("utf-8"))
    atomic_write(SURGE_FILE, surge.encode("utf-8"))
    print(f"Updated {SOURCE_FILE.relative_to(ROOT)}")
    print(f"Generated {SURGE_FILE.relative_to(ROOT)} with {count} rules")


if __name__ == "__main__":
    main()
