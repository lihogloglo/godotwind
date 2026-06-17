#!/usr/bin/env python3
"""Inventory Godotwind performance, loading, and diagnostic surfaces.

This script is intentionally static. It does not launch Godot or mutate the
project. It gives future agents a repeatable first pass before deciding what
benchmark/diagnostic slice to implement next.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


TEXT_EXTENSIONS = {".gd", ".cs", ".md", ".tscn", ".tres", ".json", ".cfg", ".godot"}
SKIP_DIRS = {
    ".git",
    ".godot",
    ".mono",
    ".import",
    "addons",
    "bin",
    "obj",
    "reports",
    "tmp",
    ".pytest_cache",
}
TARGET_ROOTS = [
    "src/core",
    "src/tools",
    "src/native",
    "tests/unit",
    "tests/benchmark",
    "tests/diagnostic",
    "tests/visual",
    "docs/audit",
    "docs/systems",
    "docs/plans",
]


PATTERNS: dict[str, list[str]] = {
    "performance_builtin_monitor": [
        r"Performance\.get_monitor",
        r"Performance\.[A-Z0-9_]+",
    ],
    "performance_custom_monitor": [
        r"add_custom_monitor",
        r"get_custom_monitor",
    ],
    "benchmark_runner": [
        r"benchmark",
        r"bench_",
        r"Benchmark",
        r"benchmark_results",
    ],
    "structured_report": [
        r"JSON",
        r"json",
        r"CSV",
        r"csv",
        r"summary",
        r"baseline",
    ],
    "streaming_metric": [
        r"queue",
        r"loaded_cells",
        r"async_requests",
        r"frame_budget",
        r"publication_budget",
        r"stream_total_ms",
    ],
    "loading_metric": [
        r"startup",
        r"first_playable",
        r"loading_time",
        r"loading_finished",
        r"cold",
        r"warm",
    ],
    "memory_or_leak_metric": [
        r"OBJECT_COUNT",
        r"OBJECT_NODE_COUNT",
        r"OBJECT_RESOURCE_COUNT",
        r"OBJECT_ORPHAN_NODE_COUNT",
        r"MEMORY_",
        r"ObjectDB",
        r"leak",
    ],
    "pipeline_compile_metric": [
        r"PIPELINE_COMPILATIONS",
        r"PipelineCompile",
        r"pipeline_compile",
    ],
    "hot_path_gdscript_signal": [
        r"func _process",
        r"func _physics_process",
        r"WorkerThreadPool",
        r"ResourceLoader",
        r"load_threaded",
        r"Time\.get_ticks",
        r"for .* in ",
        r"while ",
    ],
    "native_or_csharp_surface": [
        r"partial class",
        r"GodotObject",
        r"Native",
        r"src/native",
        r"C#",
    ],
}


KNOWN_SURFACES = {
    "benchmarking_doc": "docs/systems/benchmarking.md",
    "loading_doc": "docs/systems/loading.md",
    "model_loading_doc": "docs/systems/model_loading.md",
    "thresholds": "tests/benchmark/benchmark_thresholds.gd",
    "streaming_benchmark": "src/tools/streaming_benchmark.gd",
    "streaming_stress_runner": "src/tools/streaming_stress_runner.gd",
    "auto_bench_runner": "src/tools/auto_bench_runner.gd",
    "bench_ladder_runner": "src/tools/bench_ladder_runner.gd",
    "progressive_benchmark": "src/tools/progressive_benchmark.gd",
    "benchmark_hud": "src/tools/benchmark_hud.gd",
    "subsystem_toggles": "src/tools/subsystem_toggles.gd",
    "performance_profiler": "src/core/world/performance_profiler.gd",
    "streaming_profiler": "src/core/world/streaming_profiler.gd",
    "pipeline_compile_monitor": "src/core/diagnostics/pipeline_compile_monitor.gd",
    "native_streaming_manager": "src/core/world/native_streaming_manager.gd",
    "world_explorer": "src/tools/world_explorer.gd",
}


@dataclass
class Hit:
    path: str
    line: int
    text: str


@dataclass
class ScanResult:
    generated_at: str
    root: str
    known_surfaces: dict[str, bool] = field(default_factory=dict)
    hits: dict[str, list[Hit]] = field(default_factory=dict)
    file_counts: dict[str, int] = field(default_factory=dict)
    gdscript_hot_path_candidates: list[str] = field(default_factory=list)
    gaps: list[str] = field(default_factory=list)


def iter_text_files(root: Path) -> Iterable[Path]:
    for target in TARGET_ROOTS:
        base = root / target
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if path.is_dir():
                continue
            rel_parts = set(path.relative_to(root).parts)
            if rel_parts & SKIP_DIRS:
                continue
            if path.suffix.lower() in TEXT_EXTENSIONS:
                yield path


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return path.read_text(encoding="utf-8", errors="ignore")


def add_hit(hits: dict[str, list[Hit]], category: str, path: Path, root: Path, line: int, text: str) -> None:
    hits.setdefault(category, []).append(
        Hit(path=path.relative_to(root).as_posix(), line=line, text=text.strip()[:220])
    )


def bucket_for(path: Path, root: Path) -> str:
    rel = path.relative_to(root).as_posix()
    if rel.startswith("src/native/"):
        return "src-native"
    if rel.startswith("src/core/"):
        return "src-core"
    if rel.startswith("src/tools/"):
        return "src-tools"
    if rel.startswith("tests/benchmark/"):
        return "tests-benchmark"
    if rel.startswith("tests/diagnostic/"):
        return "tests-diagnostic"
    if rel.startswith("tests/visual/"):
        return "tests-visual"
    if rel.startswith("tests/unit/"):
        return "tests-unit"
    if rel.startswith("docs/audit/"):
        return "docs-audit"
    if rel.startswith("docs/systems/"):
        return "docs-systems"
    return "other"


def scan(root: Path) -> ScanResult:
    result = ScanResult(
        generated_at=datetime.now(timezone.utc).isoformat(),
        root=str(root.resolve()),
    )
    result.known_surfaces = {
        name: (root / rel).exists() for name, rel in KNOWN_SURFACES.items()
    }

    category_regexes = {
        category: [re.compile(pattern, re.IGNORECASE) for pattern in patterns]
        for category, patterns in PATTERNS.items()
    }

    hot_scores: dict[str, int] = {}
    for path in iter_text_files(root):
        bucket = bucket_for(path, root)
        result.file_counts[bucket] = result.file_counts.get(bucket, 0) + 1
        text = read_text(path)
        rel = path.relative_to(root).as_posix()
        for line_no, line in enumerate(text.splitlines(), start=1):
            for category, regexes in category_regexes.items():
                if any(regex.search(line) for regex in regexes):
                    add_hit(result.hits, category, path, root, line_no, line)
                    if category == "hot_path_gdscript_signal" and path.suffix == ".gd" and rel.startswith("src/"):
                        hot_scores[rel] = hot_scores.get(rel, 0) + 1

    result.gdscript_hot_path_candidates = [
        path for path, _score in sorted(hot_scores.items(), key=lambda item: (-item[1], item[0]))[:30]
    ]
    result.gaps = infer_gaps(result)
    return result


def infer_gaps(result: ScanResult) -> list[str]:
    gaps: list[str] = []
    if not result.hits.get("performance_custom_monitor"):
        gaps.append("No custom Performance.add_custom_monitor usage found; Godotwind-specific metrics may not appear in Godot's Monitors panel.")
    if not result.hits.get("memory_or_leak_metric"):
        gaps.append("No memory/object/leak metric references found in scan results.")
    if not result.hits.get("pipeline_compile_metric"):
        gaps.append("No pipeline compilation metric references found in scan results.")
    if not result.hits.get("loading_metric"):
        gaps.append("No loading/startup/first-playable metric references found in scan results.")
    if not result.known_surfaces.get("thresholds"):
        gaps.append("Benchmark thresholds file is missing.")
    if not result.known_surfaces.get("benchmarking_doc"):
        gaps.append("Benchmarking system documentation is missing.")
    if result.gdscript_hot_path_candidates:
        gaps.append("GDScript hot-path candidates exist; Pillar 3/5 should require evidence before C# migration.")
    return gaps


def to_jsonable(result: ScanResult) -> dict:
    return {
        "generated_at": result.generated_at,
        "root": result.root,
        "known_surfaces": result.known_surfaces,
        "file_counts": result.file_counts,
        "hits": {
            category: [hit.__dict__ for hit in hits[:200]]
            for category, hits in sorted(result.hits.items())
        },
        "hit_counts": {category: len(hits) for category, hits in sorted(result.hits.items())},
        "gdscript_hot_path_candidates": result.gdscript_hot_path_candidates,
        "gaps": result.gaps,
    }


def write_markdown(result: ScanResult, path: Path) -> None:
    lines: list[str] = []
    lines.append("# Performance Observatory Scan")
    lines.append("")
    lines.append(f"Generated: `{result.generated_at}`")
    lines.append(f"Root: `{result.root}`")
    lines.append("")
    lines.append("## Known Surfaces")
    lines.append("")
    lines.append("| Surface | Present |")
    lines.append("|---|---:|")
    for name, present in sorted(result.known_surfaces.items()):
        lines.append(f"| `{name}` | {'yes' if present else 'NO'} |")
    lines.append("")
    lines.append("## File Counts")
    lines.append("")
    lines.append("| Bucket | Files |")
    lines.append("|---|---:|")
    for bucket, count in sorted(result.file_counts.items()):
        lines.append(f"| `{bucket}` | {count} |")
    lines.append("")
    lines.append("## Hit Counts")
    lines.append("")
    lines.append("| Category | Hits |")
    lines.append("|---|---:|")
    for category, hits in sorted(result.hits.items()):
        lines.append(f"| `{category}` | {len(hits)} |")
    lines.append("")
    lines.append("## GDScript Hot-Path Candidates")
    lines.append("")
    if result.gdscript_hot_path_candidates:
        for candidate in result.gdscript_hot_path_candidates:
            lines.append(f"- `{candidate}`")
    else:
        lines.append("- None found by static heuristic.")
    lines.append("")
    lines.append("## Inferred Gaps")
    lines.append("")
    if result.gaps:
        for gap in result.gaps:
            lines.append(f"- {gap}")
    else:
        lines.append("- No static gaps inferred.")
    lines.append("")
    lines.append("## Sample Hits")
    for category, hits in sorted(result.hits.items()):
        lines.append("")
        lines.append(f"### `{category}`")
        for hit in hits[:12]:
            lines.append(f"- `{hit.path}:{hit.line}` {hit.text}")
        if len(hits) > 12:
            lines.append(f"- ... {len(hits) - 12} more")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".", help="Project root")
    parser.add_argument("--out-md", default="reports/performance_observatory_scan.md")
    parser.add_argument("--out-json", default="reports/performance_observatory_scan.json")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    result = scan(root)

    out_md = root / args.out_md
    out_json = root / args.out_json
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_json.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(result, out_md)
    out_json.write_text(json.dumps(to_jsonable(result), indent=2), encoding="utf-8")

    print(f"Wrote {out_md}")
    print(f"Wrote {out_json}")
    print("Hit counts:")
    for category, hits in sorted(result.hits.items()):
        print(f"  {category}: {len(hits)}")
    if result.gaps:
        print("Inferred gaps:")
        for gap in result.gaps:
            print(f"  - {gap}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
