#!/usr/bin/env python3
"""
Aggregate Google Benchmark JSON results from a Phase 1 (counter) result directory.

Usage:
    python3 aggregate.py <result_dir>

Reads all gbench_*.json files in <result_dir>. For each (benchmark, counter) pair
computes:
    - sample mean and Bessel-corrected stddev (denominator n-1)
    - coefficient of variation
    - 95% percentile bootstrap CI using a HIERARCHICAL resample (resample whole
      invocation files, then average within each, to respect that iterations
      within an invocation are not independent observations)

Writes summary.csv next to the inputs and emits a stderr warning for any
counter whose CV exceeds CV_WARN_THRESHOLD.

Deterministic: random.seed(SEED) is set before bootstrap resampling.
"""

from __future__ import annotations

import csv
import json
import math
import random
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

BOOTSTRAP_SAMPLES = 10_000
CI_ALPHA = 0.05
CV_WARN_THRESHOLD = 0.05   # 5% — flag counters whose run-to-run CV is suspicious
SEED = 42

# Standard gbench fields that are not hardware counters or metric values.
_GBENCH_META_KEYS = frozenset({
    "name", "run_name", "run_type", "repetitions", "repetition_index",
    "threads", "iterations", "time_unit", "aggregate_name", "aggregate_unit",
    "family_index", "per_family_instance_index", "label",
})


def _is_metric_key(key: str) -> bool:
    return key not in _GBENCH_META_KEYS


@dataclass
class Observation:
    bench: str          # e.g. "BM_ParticleSimulation/512"
    counter: str        # e.g. "llc_misses_forces"
    value: float
    invocation: str     # the source filename — gbench_<ts>.json — used as resample unit


def load_observations(result_dir: Path) -> List[Observation]:
    """Walk gbench_*.json files and emit one Observation per (file, bench, counter, iteration row)."""
    json_files = sorted(result_dir.glob("gbench_*.json"))
    if not json_files:
        print(f"[ERROR] No gbench_*.json files found in {result_dir}", file=sys.stderr)
        sys.exit(1)

    obs: List[Observation] = []
    for path in json_files:
        try:
            with path.open() as f:
                report = json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            print(f"[WARN] Skipping unreadable {path.name}: {e}", file=sys.stderr)
            continue

        for bench in report.get("benchmarks", []):
            if bench.get("run_type") != "iteration":
                continue
            name = bench.get("name", "?")
            for key, val in bench.items():
                if key in _GBENCH_META_KEYS:
                    continue
                if isinstance(val, (int, float)) and not isinstance(val, bool):
                    obs.append(Observation(
                        bench=name,
                        counter=key,
                        value=float(val),
                        invocation=path.name,
                    ))
    return obs


def hierarchical_bootstrap_ci(
    grouped: Dict[str, List[float]],
    n_samples: int,
    alpha: float,
) -> Tuple[float, float]:
    """Resample invocations (with replacement), then take the mean of each invocation's
    iteration values, then take the grand mean across resampled invocations.
    Repeat n_samples times → percentile CI.
    """
    invocations = list(grouped.keys())
    if not invocations:
        return float("nan"), float("nan")
    if len(invocations) == 1:
        # Cannot resample at the invocation level — fall back to flat bootstrap.
        flat = grouped[invocations[0]]
        if not flat:
            return float("nan"), float("nan")
        means = []
        n = len(flat)
        for _ in range(n_samples):
            sample = [random.choice(flat) for _ in range(n)]
            means.append(sum(sample) / n)
        means.sort()
        lo = means[int(alpha / 2 * n_samples)]
        hi = means[int((1 - alpha / 2) * n_samples)]
        return lo, hi

    # Pre-compute per-invocation means.
    inv_means = {inv: (sum(vs) / len(vs) if vs else float("nan")) for inv, vs in grouped.items()}
    valid_invs = [i for i in invocations if not math.isnan(inv_means[i])]
    if not valid_invs:
        return float("nan"), float("nan")

    grand_means: List[float] = []
    n = len(valid_invs)
    for _ in range(n_samples):
        resample = [random.choice(valid_invs) for _ in range(n)]
        grand_means.append(sum(inv_means[i] for i in resample) / n)
    grand_means.sort()
    lo = grand_means[int(alpha / 2 * n_samples)]
    hi = grand_means[int((1 - alpha / 2) * n_samples)]
    return lo, hi


def summarize(obs: List[Observation]) -> List[dict]:
    # Group: (bench, counter) → invocation → [values]
    grouped: Dict[Tuple[str, str], Dict[str, List[float]]] = {}
    for o in obs:
        grouped.setdefault((o.bench, o.counter), {}).setdefault(o.invocation, []).append(o.value)

    rows: List[dict] = []
    for (bench, counter), per_inv in sorted(grouped.items()):
        all_values = [v for vs in per_inv.values() for v in vs]
        n_total = len(all_values)
        n_invs = len(per_inv)
        if n_total == 0:
            continue

        mean = sum(all_values) / n_total
        # Bessel-corrected sample stddev
        if n_total > 1:
            variance = sum((v - mean) ** 2 for v in all_values) / (n_total - 1)
            stddev = math.sqrt(variance)
        else:
            stddev = 0.0
        cv = stddev / mean if mean != 0 else 0.0

        # Per-invocation means → between-invocation CV (the more meaningful one for
        # run-to-run stability assessment).
        inv_means = [sum(vs) / len(vs) for vs in per_inv.values() if vs]
        if len(inv_means) > 1:
            mu = sum(inv_means) / len(inv_means)
            inv_var = sum((m - mu) ** 2 for m in inv_means) / (len(inv_means) - 1)
            inv_stddev = math.sqrt(inv_var)
            inv_cv = inv_stddev / mu if mu != 0 else 0.0
        else:
            inv_cv = 0.0

        ci_lo, ci_hi = hierarchical_bootstrap_ci(per_inv, BOOTSTRAP_SAMPLES, CI_ALPHA)

        rows.append({
            "benchmark": bench,
            "counter": counter,
            "n_iterations": n_total,
            "n_invocations": n_invs,
            "mean": mean,
            "stddev": stddev,
            "cv": cv,
            "between_invocation_cv": inv_cv,
            "ci95_lo": ci_lo,
            "ci95_hi": ci_hi,
        })
    return rows


def write_csv(rows: List[dict], out_path: Path) -> None:
    fieldnames = [
        "benchmark", "counter", "n_iterations", "n_invocations",
        "mean", "stddev", "cv", "between_invocation_cv",
        "ci95_lo", "ci95_hi",
    ]
    with out_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    print(f"[INFO] Wrote {len(rows)} rows → {out_path}")


def warn_high_cv(rows: List[dict]) -> int:
    """Emit stderr warnings for any counter whose between-invocation CV exceeds threshold.
    Wall-clock timing counters are the most important to flag.
    Returns count of warnings.
    """
    n_warn = 0
    for r in rows:
        # Only warn on between-invocation CV — within-invocation noise is inherent to gbench.
        if r["n_invocations"] >= 2 and r["between_invocation_cv"] > CV_WARN_THRESHOLD:
            print(
                f"[WARN] High between-invocation CV "
                f"({r['between_invocation_cv']*100:.2f}%) for "
                f"{r['benchmark']}/{r['counter']} "
                f"(n_inv={r['n_invocations']}, mean={r['mean']:.4g})",
                file=sys.stderr,
            )
            n_warn += 1
    return n_warn


def main() -> None:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <result_dir>", file=sys.stderr)
        sys.exit(1)

    result_dir = Path(sys.argv[1])
    if not result_dir.is_dir():
        print(f"[ERROR] Not a directory: {result_dir}", file=sys.stderr)
        sys.exit(1)

    random.seed(SEED)
    obs = load_observations(result_dir)
    rows = summarize(obs)
    if not rows:
        print("[ERROR] No iteration data found", file=sys.stderr)
        sys.exit(1)

    write_csv(rows, result_dir / "summary.csv")
    n_warn = warn_high_cv(rows)
    if n_warn:
        print(f"[INFO] {n_warn} counter(s) flagged as noisy (CV > {CV_WARN_THRESHOLD*100:.0f}%).",
              file=sys.stderr)


if __name__ == "__main__":
    main()
