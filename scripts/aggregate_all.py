#!/usr/bin/env python3
"""
Master aggregator: walk a results/ tree and emit a single tall-format CSV
suitable for plotting and statistical analysis.

Expected directory layout (created by run_all.sh / bench.sh):

    results/
    └── <compiler>/                       # gcc | clang
        └── <workload>/                   # particle | matrix
            └── <variant>/                # aos | soa | aligned | row_major | tile_contiguous
                └── <opt>/                # O2 | O3 | O3_native
                    ├── counter/          # Phase 1
                    │   └── gbench_*.json
                    ├── perf/             # Phase 2
                    │   ├── b1_cache/
                    │   │   ├── perf_*.csv
                    │   │   └── gbench_*.json
                    │   ├── b2_tlb/
                    │   └── b3_stalls/
                    └── sampling/         # Phase 3
                        ├── perf_*.data
                        ├── annotate_*.txt
                        └── report_*.csv

Output (one row per (compiler, opt, workload, variant, phase, n, counter, statistic)):

    compiler, opt, workload, variant, phase, bench_arg, counter,
    mean, stddev, cv, between_invocation_cv, ci95_lo, ci95_hi,
    n_iterations, n_invocations, source

Where:
  - phase ∈ {counter, perf_b1_cache, perf_b2_tlb, perf_b3_stalls, sampling}
  - bench_arg is the gbench Arg() value (particle N) or empty for matrix
  - source identifies the file format (gbench_json | perf_stat_csv | perf_report)

Usage:
    python3 aggregate_all.py <results_root> [-o master.csv]
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import random
import re
import statistics
import sys
from collections import defaultdict
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

# Make the per-directory aggregator's helpers importable.
SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import aggregate as _agg                              # noqa: E402
import parse_perf_stat as _ps                         # noqa: E402

random.seed(_agg.SEED)


# ── Path parsing ──────────────────────────────────────────────────────────────

# We walk dirs like:
#   results/gcc/particle/soa/O3/counter
#   results/clang/matrix/tile_contiguous/O2/perf/b1_cache
#   results/gcc/particle/aos/O3/sampling
# Older layouts without compiler segment also work — compiler is recorded as "unknown".

_KNOWN_COMPILERS = {"gcc", "clang", "g++", "clang++"}
_KNOWN_WORKLOADS = {"particle", "matrix"}
_KNOWN_OPTS = {"O0", "O1", "O2", "O3", "O3_native", "Os", "Oz"}


@dataclass(frozen=True)
class CellId:
    compiler: str
    workload: str
    variant: str
    opt: str
    phase: str          # 'counter' | 'perf_b1_cache' | ... | 'sampling'

    def to_dict(self) -> dict:
        return asdict(self)


def parse_cell_path(root: Path, path: Path) -> Optional[Tuple[CellId, Path]]:
    """Given a candidate leaf directory, infer (compiler, workload, variant, opt, phase).

    Returns None if the path doesn't fit either expected shape.
    """
    try:
        rel = path.relative_to(root)
    except ValueError:
        return None
    parts = rel.parts

    # Phase 2 splits into b{1,2,3}_*: the leaf is the b*_* dir, parent is "perf".
    # Try to detect that and fold it into a single phase tag.
    phase: Optional[str] = None
    base_parts: Tuple[str, ...] = ()
    if len(parts) >= 2 and parts[-2] == "perf" and parts[-1].startswith("b"):
        phase = f"perf_{parts[-1]}"
        base_parts = parts[:-2]
    elif parts and parts[-1] in ("counter", "perf", "sampling"):
        phase = parts[-1]
        base_parts = parts[:-1]
    else:
        return None

    # base_parts: [<compiler>] <workload> <variant> <opt>
    if len(base_parts) == 4 and base_parts[0] in _KNOWN_COMPILERS:
        compiler, workload, variant, opt = base_parts
    elif len(base_parts) == 3:
        compiler = "unknown"
        workload, variant, opt = base_parts
    else:
        return None

    if workload not in _KNOWN_WORKLOADS:
        return None
    if opt not in _KNOWN_OPTS:
        # Tolerate unknown opts but still record them.
        pass

    return CellId(compiler=compiler, workload=workload, variant=variant,
                  opt=opt, phase=phase), path


def find_cells(root: Path) -> List[Tuple[CellId, Path]]:
    """Find every benchmark cell directory under `root`."""
    cells: List[Tuple[CellId, Path]] = []
    for path in root.rglob("*"):
        if not path.is_dir():
            continue
        parsed = parse_cell_path(root, path)
        if parsed is not None:
            cells.append(parsed)
    return cells


# ── Phase 1 / Phase 2-gbench rows from gbench_*.json ──────────────────────────

def _summarize_observations(obs: List[_agg.Observation]) -> Iterable[dict]:
    """Same logic as aggregate.summarize, but returns dicts."""
    return _agg.summarize(obs)


def _bench_arg_from_name(bench_name: str) -> str:
    """Extract the Arg() suffix from gbench names like 'BM_ParticleSimulation/512'."""
    m = re.search(r"/(\d+)", bench_name)
    return m.group(1) if m else ""


def collect_gbench_rows(cell: CellId, dir_path: Path) -> List[dict]:
    """Read all gbench_*.json files in dir_path, summarise to one row per
    (benchmark, counter), and stamp the cell metadata.
    """
    if not any(dir_path.glob("gbench_*.json")):
        return []
    obs = _agg.load_observations(dir_path)
    summary_rows = _agg.summarize(obs)

    out: List[dict] = []
    for r in summary_rows:
        out.append({
            **cell.to_dict(),
            "bench_arg": _bench_arg_from_name(r["benchmark"]),
            "benchmark": r["benchmark"],
            "counter": r["counter"],
            "mean": r["mean"],
            "stddev": r["stddev"],
            "cv": r["cv"],
            "between_invocation_cv": r["between_invocation_cv"],
            "ci95_lo": r["ci95_lo"],
            "ci95_hi": r["ci95_hi"],
            "n_iterations": r["n_iterations"],
            "n_invocations": r["n_invocations"],
            "source": "gbench_json",
        })
    return out


# ── Phase 2 rows from perf stat CSV ───────────────────────────────────────────

def collect_perfstat_rows(cell: CellId, dir_path: Path) -> List[dict]:
    """Read all perf_*.csv files in a Phase 2 leaf and aggregate counts per event
    across the multiple invocation files (each file already represents -r N
    averaged inside)."""
    csv_files = sorted(dir_path.glob("perf_*.csv"))
    if not csv_files:
        return []

    # event → list of per-file (count, stddev_pct) tuples
    per_event: Dict[str, List[Tuple[float, float]]] = defaultdict(list)
    for cf in csv_files:
        for row in _ps.parse_perf_stat_csv(cf):
            if row.is_valid():
                per_event[row.event].append((row.count, row.stddev_pct))

    out: List[dict] = []
    for event, pairs in sorted(per_event.items()):
        counts = [c for c, _ in pairs if not math.isnan(c)]
        if not counts:
            continue
        mean = statistics.fmean(counts)
        stddev = statistics.stdev(counts) if len(counts) > 1 else 0.0
        cv = stddev / mean if mean != 0 else 0.0

        if len(counts) > 1:
            ci_lo, ci_hi = _agg.hierarchical_bootstrap_ci(
                {f"f{i}": [c] for i, c in enumerate(counts)},
                _agg.BOOTSTRAP_SAMPLES,
                _agg.CI_ALPHA,
            )
        else:
            ci_lo = ci_hi = mean

        out.append({
            **cell.to_dict(),
            "bench_arg": "",
            "benchmark": "",
            "counter": event,
            "mean": mean,
            "stddev": stddev,
            "cv": cv,
            "between_invocation_cv": cv,    # one observation per invocation here
            "ci95_lo": ci_lo,
            "ci95_hi": ci_hi,
            "n_iterations": len(counts),    # one per invocation
            "n_invocations": len(counts),
            "source": "perf_stat_csv",
        })
    return out


# ── Phase 3 rows from perf report ─────────────────────────────────────────────

def collect_perfreport_rows(cell: CellId, dir_path: Path) -> List[dict]:
    """Phase 3 sampling: read the latest report_*.csv and emit one row per
    top-N symbol with overhead percentage and sample count.
    """
    report_files = sorted(dir_path.glob("report_*.csv"))
    if not report_files:
        return []
    latest = report_files[-1]
    rows = _ps.parse_perf_report_csv(latest, top_n=20)
    out: List[dict] = []
    for r in rows:
        out.append({
            **cell.to_dict(),
            "bench_arg": "",
            "benchmark": f"{r['symbol']}@{r['srcfile']}:{r['srcline']}" if r['srcline'] >= 0 else r['symbol'],
            "counter": "llc_miss_overhead_pct",
            "mean": r["overhead_pct"],
            "stddev": 0.0,
            "cv": 0.0,
            "between_invocation_cv": 0.0,
            "ci95_lo": r["overhead_pct"],
            "ci95_hi": r["overhead_pct"],
            "n_iterations": r["samples"],
            "n_invocations": 1,
            "source": "perf_report",
        })
    return out


# ── Driver ────────────────────────────────────────────────────────────────────

_FIELDNAMES = [
    "compiler", "workload", "variant", "opt", "phase",
    "bench_arg", "benchmark", "counter",
    "mean", "stddev", "cv", "between_invocation_cv",
    "ci95_lo", "ci95_hi",
    "n_iterations", "n_invocations",
    "source",
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results_root", type=Path,
                        help="Root of the results tree (e.g. ./results)")
    parser.add_argument("-o", "--output", type=Path, default=None,
                        help="Output CSV path (default: <results_root>/master.csv)")
    parser.add_argument("--cv-threshold", type=float, default=_agg.CV_WARN_THRESHOLD,
                        help="Between-invocation CV warning threshold (default: 0.05)")
    args = parser.parse_args()

    if not args.results_root.is_dir():
        print(f"[ERROR] Not a directory: {args.results_root}", file=sys.stderr)
        return 1

    output = args.output or (args.results_root / "master.csv")

    cells = find_cells(args.results_root)
    if not cells:
        print(f"[ERROR] No benchmark cells found under {args.results_root}", file=sys.stderr)
        return 1

    print(f"[INFO] Found {len(cells)} benchmark cell(s)")
    all_rows: List[dict] = []
    for cell, path in cells:
        if cell.phase == "counter":
            rows = collect_gbench_rows(cell, path)
        elif cell.phase.startswith("perf_"):
            rows = collect_gbench_rows(cell, path)            # the timing JSON
            rows += collect_perfstat_rows(cell, path)         # the perf stat CSV
        elif cell.phase == "sampling":
            rows = collect_perfreport_rows(cell, path)
        else:
            rows = []
        if rows:
            print(f"[INFO]   {cell.compiler}/{cell.workload}/{cell.variant}/{cell.opt}/{cell.phase}: {len(rows)} rows")
        all_rows.extend(rows)

    if not all_rows:
        print("[WARN] No rows extracted — empty result tree?", file=sys.stderr)
        return 1

    # Fix IPC scaling: Google Benchmark's kAvgIterations flag divides IPC by iteration count.
    # Restore true IPC by multiplying by n_iterations.
    ipc_fixed = 0
    for row in all_rows:
        if "ipc" in row["counter"].lower() and row["n_iterations"] > 0:
            for metric in ["mean", "stddev", "ci95_lo", "ci95_hi"]:
                if metric in row and row[metric] is not None:
                    row[metric] *= row["n_iterations"]
            ipc_fixed += 1
    if ipc_fixed > 0:
        print(f"[INFO] Fixed IPC scaling on {ipc_fixed} row(s) (multiplied by n_iterations)")

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=_FIELDNAMES)
        writer.writeheader()
        writer.writerows(all_rows)
    print(f"[INFO] Wrote {len(all_rows)} rows → {output}")

    # Roll up CV warnings.
    n_warn = 0
    for r in all_rows:
        if r["n_invocations"] >= 2 and r["between_invocation_cv"] > args.cv_threshold:
            n_warn += 1
            print(
                f"[WARN] CV={r['between_invocation_cv']*100:.1f}% "
                f"in {r['compiler']}/{r['workload']}/{r['variant']}/{r['opt']}/{r['phase']} "
                f"counter={r['counter']} bench_arg={r['bench_arg']}",
                file=sys.stderr,
            )
    if n_warn:
        print(f"[INFO] {n_warn} counter/cell pair(s) exceeded CV threshold "
              f"{args.cv_threshold*100:.1f}%.", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
