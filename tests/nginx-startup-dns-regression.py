#!/usr/bin/env python3
"""Regression checks for Nginx configs that must survive early-boot DNS gaps."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

EXTERNAL_UPSTREAM_HOSTS = (
    "github.com",
    "raw.githubusercontent.com",
    "gist.github.com",
    "gist.githubusercontent.com",
    "github.githubassets.com",
    "codeload.github.com",
    "objects.githubusercontent.com",
    "github-releases.githubusercontent.com",
)

CONFIG_DIRS = (
    ROOT / "conf.d",
    ROOT / "rendered-test" / "conf.d",
)

HOST_PATTERN = "|".join(re.escape(host) for host in EXTERNAL_UPSTREAM_HOSTS)

STATIC_SERVER_RE = re.compile(
    rf"(?m)^\s*server\s+({HOST_PATTERN})(?::\d+)?\s*;"
)

STATIC_PROXY_PASS_RE = re.compile(
    rf"(?m)^\s*proxy_pass\s+https://({HOST_PATTERN})(?:[:/;]|$)"
)


def iter_nginx_configs() -> list[Path]:
    files: list[Path] = []
    for directory in CONFIG_DIRS:
        files.extend(sorted(directory.glob("*.conf")))
    return files


def main() -> int:
    bad: list[str] = []
    missing_resolver: list[str] = []
    for path in iter_nginx_configs():
        text = path.read_text(encoding="utf-8", errors="ignore")
        for regex in (STATIC_SERVER_RE, STATIC_PROXY_PASS_RE):
            for match in regex.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                bad.append(f"{path.relative_to(ROOT)}:{line}: {match.group(0).strip()}")
        if "proxy_pass https://$" in text and "mirror-resolver.conf" not in text and "resolver " not in text:
            missing_resolver.append(str(path.relative_to(ROOT)))

    if bad or missing_resolver:
        if bad:
            print("Startup-time external DNS dependencies force Nginx to resolve upstream hosts before serving.")
            print("Use resolver + variable proxy_pass for GitHub-owned upstream hosts instead.")
            print()
            print("Offending directives:")
            for item in bad:
                print(f"  - {item}")
        if missing_resolver:
            print()
            print("Variable proxy_pass configs must include a resolver:")
            for item in missing_resolver:
                print(f"  - {item}")
        return 1

    print("OK: no startup-time external upstream DNS dependencies found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
