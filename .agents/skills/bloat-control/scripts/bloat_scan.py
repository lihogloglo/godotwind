#!/usr/bin/env python3
"""Summarize Godotwind LOC and file categories for bloat-control audits."""

from __future__ import annotations

import argparse
import subprocess
from dataclasses import dataclass
from pathlib import Path


TEXT_EXTS = {
    ".cs",
    ".gd",
    ".gdshader",
    ".gdshaderinc",
    ".glsl",
    ".glslinc",
    ".json",
    ".md",
    ".py",
    ".tres",
    ".tscn",
    ".txt",
    ".xml",
    ".yaml",
    ".yml",
}

GENERATED_PREFIXES = (
    "reports/",
    ".godot/",
    ".import/",
)


@dataclass
class FileStat:
    path: str
    category: str
    lines: int


def run_git(root: Path, args: list[str]) -> list[str]:
    result = subprocess.run(
        ["git", *args],
        cwd=root,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return [line.strip().replace("\\", "/") for line in result.stdout.splitlines() if line.strip()]


def line_count(path: Path) -> int:
    if path.suffix.lower() not in TEXT_EXTS:
        return 0
    try:
        with path.open("r", encoding="utf-8", errors="ignore") as handle:
            return sum(1 for _ in handle)
    except OSError:
        return 0


def categorize(path: str) -> str:
    p = path.replace("\\", "/")
    if p.startswith(GENERATED_PREFIXES):
        return "generated"
    if p.startswith(".agents/skills/"):
        return "agent-skills"
    if p.startswith("docs/audit/"):
        return "docs-audit"
    if p.startswith("docs/plans/"):
        return "docs-plans"
    if p.startswith("docs/archive/"):
        return "docs-archive"
    if p.startswith("docs/"):
        return "docs"
    if p.startswith("tests/unit/"):
        return "tests-unit"
    if p.startswith("tests/visual/"):
        return "tests-visual"
    if p.startswith("tests/benchmark/"):
        return "tests-benchmark"
    if p.startswith("tests/diagnostic/"):
        return "tests-diagnostic"
    if p.startswith("tests/"):
        return "tests-other"
    if p.startswith("src/native/"):
        return "src-native"
    if "/morrowind/" in p and p.startswith("src/"):
        return "src-morrowind-adapter"
    if p.startswith("src/tools/"):
        return "src-tools"
    if p.startswith("src/core/"):
        return "src-core"
    if p.startswith("src/"):
        return "src-other"
    if p.endswith(".uid"):
        return "uid"
    return "other"


def collect_stats(root: Path, include_untracked: bool) -> list[FileStat]:
    files = set(run_git(root, ["ls-files"]))
    if include_untracked:
        files.update(run_git(root, ["ls-files", "--others", "--exclude-standard"]))
    stats: list[FileStat] = []
    for rel in sorted(files):
        full = root / rel
        if not full.is_file():
            continue
        stats.append(FileStat(rel, categorize(rel), line_count(full)))
    return stats


def print_category_summary(stats: list[FileStat]) -> None:
    totals: dict[str, tuple[int, int]] = {}
    for stat in stats:
        count, lines = totals.get(stat.category, (0, 0))
        totals[stat.category] = (count + 1, lines + stat.lines)

    print("CATEGORY_SUMMARY")
    print("category,files,lines")
    for category, (count, lines) in sorted(totals.items()):
        print(f"{category},{count},{lines}")


def print_top(stats: list[FileStat], prefix: str, limit: int) -> None:
    selected = [stat for stat in stats if stat.category.startswith(prefix)]
    selected.sort(key=lambda stat: stat.lines, reverse=True)
    print(f"\nTOP_{prefix.upper().replace('-', '_')}")
    print("lines,path")
    for stat in selected[:limit]:
        print(f"{stat.lines},{stat.path}")


def print_changed_summary(root: Path) -> None:
    try:
        shortstat = subprocess.run(
            ["git", "diff", "--shortstat"],
            cwd=root,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout.strip()
    except subprocess.CalledProcessError:
        shortstat = ""
    print("\nGIT_DIFF_SHORTSTAT")
    print(shortstat if shortstat else "(no tracked diff)")

    untracked = run_git(root, ["ls-files", "--others", "--exclude-standard"])
    print("\nUNTRACKED_COUNT")
    print(len(untracked))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".", help="Repository root")
    parser.add_argument("--top", type=int, default=25, help="Top files per selected category")
    parser.add_argument(
        "--tracked-only",
        action="store_true",
        help="Ignore untracked files",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    stats = collect_stats(root, include_untracked=not args.tracked_only)
    print_changed_summary(root)
    print()
    print_category_summary(stats)
    print_top(stats, "src", args.top)
    print_top(stats, "tests", args.top)
    print_top(stats, "docs", args.top)
    print_top(stats, "generated", args.top)


if __name__ == "__main__":
    main()
