#!/usr/bin/env python3
"""Keep the per-architecture sha256 ARGs in the Dockerfile in sync with the
pinned `<TOOL>_VERSION` ARGs of every release binary we download.

Usage:
  refresh-checksums.py            recompute tools whose *_VERSION line changed
                                  in `git diff HEAD` (what Renovate's
                                  postUpgradeTasks needs); falls back to all
                                  tools when git is unavailable
  refresh-checksums.py --tool N   recompute one tool; N is the Renovate depName
                                  (cli/cli, cursor-agent, ...) or ARG prefix (GH)
  refresh-checksums.py --all      recompute every tool
  refresh-checksums.py --check    offline structural check: every tool has a
                                  version and two well-formed sha256 ARGs
  refresh-checksums.py --verify   download everything and fail on any drift
                                  (no file changes)

Where upstream publishes checksums, the downloaded asset is cross-checked
against them and any mismatch aborts. Cursor publishes none, so its hashes are
trust-on-first-download; the Docker build re-verifies every hash either way.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parent.parent
DOCKERFILE = ROOT / "Dockerfile"
ARCHES = ("amd64", "arm64")
UA = {"User-Agent": "deepseek-harness-dev-refresh-checksums"}


def fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=300) as resp:
        return resp.read()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sums_file_lookup(text: str, filename: str) -> str | None:
    """Parse `<hash>  <file>` (sha256sum / goreleaser) style content."""
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[-1].lstrip("*") == filename and re.fullmatch(r"[0-9a-f]{64}", parts[0]):
            return parts[0]
    return None


@dataclass
class Tool:
    key: str  # ARG prefix, e.g. GH -> GH_VERSION, GH_SHA256_AMD64
    dep: str  # Renovate depName in the Dockerfile annotation
    url: Callable[[str, str], str]  # (version, arch) -> asset URL
    published: Callable[[str, str, str], str | None] | None = None  # (version, arch, url) -> expected sha

    def filename(self, version: str, arch: str) -> str:
        return self.url(version, arch).rsplit("/", 1)[-1]


def _gh_published(v: str, arch: str, url: str) -> str | None:
    text = fetch(f"https://github.com/cli/cli/releases/download/v{v}/gh_{v}_checksums.txt").decode()
    return sums_file_lookup(text, url.rsplit("/", 1)[-1])


def _fzf_published(v: str, arch: str, url: str) -> str | None:
    text = fetch(f"https://github.com/junegunn/fzf/releases/download/v{v}/fzf_{v}_checksums.txt").decode()
    return sums_file_lookup(text, url.rsplit("/", 1)[-1])


def _atuin_published(v: str, arch: str, url: str) -> str | None:
    text = fetch(url + ".sha256").decode()
    first = text.split()
    return first[0] if first and re.fullmatch(r"[0-9a-f]{64}", first[0]) else None


def _yq_published(v: str, arch: str, url: str) -> str | None:
    base = f"https://github.com/mikefarah/yq/releases/download/v{v}"
    order = fetch(f"{base}/checksums_hashes_order").decode().split()
    try:
        idx = order.index("SHA-256")
    except ValueError:
        return None
    name = url.rsplit("/", 1)[-1]
    for line in fetch(f"{base}/checksums").decode().splitlines():
        parts = line.split()
        if parts and parts[0] == name and len(parts) > idx + 1:
            return parts[idx + 1]
    return None


ATUIN_TARGET = {"amd64": "x86_64-unknown-linux-musl", "arm64": "aarch64-unknown-linux-musl"}
CURSOR_ARCH = {"amd64": "x64", "arm64": "arm64"}

TOOLS = [
    Tool(
        "GH",
        "cli/cli",
        lambda v, a: f"https://github.com/cli/cli/releases/download/v{v}/gh_{v}_linux_{a}.deb",
        _gh_published,
    ),
    Tool(
        "YQ",
        "mikefarah/yq",
        lambda v, a: f"https://github.com/mikefarah/yq/releases/download/v{v}/yq_linux_{a}",
        _yq_published,
    ),
    Tool(
        "FZF",
        "junegunn/fzf",
        lambda v, a: f"https://github.com/junegunn/fzf/releases/download/v{v}/fzf-{v}-linux_{a}.tar.gz",
        _fzf_published,
    ),
    Tool(
        "ATUIN",
        "atuinsh/atuin",
        lambda v, a: f"https://github.com/atuinsh/atuin/releases/download/v{v}/atuin-{ATUIN_TARGET[a]}.tar.gz",
        _atuin_published,
    ),
    Tool(
        "CURSOR",
        "cursor-agent",
        lambda v, a: f"https://downloads.cursor.com/lab/{v}/linux/{CURSOR_ARCH[a]}/agent-cli-package.tar.gz",
        None,
    ),
]


def read_arg(text: str, name: str) -> str | None:
    m = re.search(rf"^ARG {name}=(\S+)$", text, re.M)
    return m.group(1) if m else None


def write_arg(text: str, name: str, value: str) -> str:
    new, n = re.subn(rf"^ARG {name}=\S+$", f"ARG {name}={value}", text, flags=re.M)
    if n != 1:
        sys.exit(f"error: expected exactly one 'ARG {name}=' line in Dockerfile, found {n}")
    return new


def changed_keys() -> set[str] | None:
    try:
        diff = subprocess.run(
            ["git", "diff", "HEAD", "--unified=0", "--", str(DOCKERFILE)],
            cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    keys = set()
    for line in diff.splitlines():
        m = re.match(r"^\+ARG ([A-Z0-9]+)_VERSION=", line)
        if m:
            keys.add(m.group(1))
    return keys


def compute(tool: Tool, version: str) -> dict[str, str]:
    out = {}
    for arch in ARCHES:
        url = tool.url(version, arch)
        print(f"  {tool.key} {version} {arch}: {url}", file=sys.stderr)
        digest = sha256(fetch(url))
        if tool.published is not None:
            expected = tool.published(version, arch, url)
            if expected is None:
                sys.exit(f"error: {tool.key} {version} {arch}: upstream checksum entry not found")
            if expected != digest:
                sys.exit(f"error: {tool.key} {version} {arch}: downloaded {digest} != published {expected}")
            print(f"    ok, matches upstream-published checksum", file=sys.stderr)
        else:
            print(f"    no upstream checksum published; trusting first download", file=sys.stderr)
        out[arch] = digest
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--tool", metavar="NAME")
    mode.add_argument("--all", action="store_true")
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--verify", action="store_true")
    args = ap.parse_args()

    text = DOCKERFILE.read_text()
    problems = []
    for tool in TOOLS:
        if read_arg(text, f"{tool.key}_VERSION") is None:
            problems.append(f"missing ARG {tool.key}_VERSION")
        for arch in ARCHES:
            val = read_arg(text, f"{tool.key}_SHA256_{arch.upper()}")
            if val is None or not re.fullmatch(r"[0-9a-f]{64}", val):
                problems.append(f"missing/malformed ARG {tool.key}_SHA256_{arch.upper()}={val}")
    if args.check:
        for p in problems:
            print(f"error: {p}", file=sys.stderr)
        if not problems:
            print(f"ok: {len(TOOLS)} tools x {len(ARCHES)} arches have well-formed checksums")
        return 1 if problems else 0

    if args.tool:
        match = [t.key for t in TOOLS if args.tool in (t.key, t.dep)]
        if not match:
            sys.exit(f"error: unknown tool {args.tool!r}; known: {', '.join(t.dep for t in TOOLS)}")
        selected = set(match)
    elif args.all or args.verify:
        selected = {t.key for t in TOOLS}
    else:
        selected = changed_keys()
        if selected is None:
            print("git diff unavailable; refreshing all tools", file=sys.stderr)
            selected = {t.key for t in TOOLS}

    drift = []
    for tool in TOOLS:
        if tool.key not in selected:
            continue
        version = read_arg(text, f"{tool.key}_VERSION")
        if version is None:
            sys.exit(f"error: missing ARG {tool.key}_VERSION")
        for arch, digest in compute(tool, version).items():
            name = f"{tool.key}_SHA256_{arch.upper()}"
            if read_arg(text, name) != digest:
                drift.append(f"{name}: {read_arg(text, name)} -> {digest}")
                if not args.verify:
                    text = write_arg(text, name, digest)

    if args.verify:
        for d in drift:
            print(f"drift: {d}", file=sys.stderr)
        return 1 if drift else 0

    if drift:
        DOCKERFILE.write_text(text)
        for d in drift:
            print(f"updated {d}")
    else:
        print("checksums already up to date" if selected else "no tool versions changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
