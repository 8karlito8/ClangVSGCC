#!/usr/bin/env python3
"""
Generate headline thesis plots from master.csv.

Produces (under <outdir>/, default <results_root>/figures/):

  1. layout_bars/                 Bar charts: counter value vs variant, faceted
                                  by compiler×opt, one PNG per (workload, counter, bench_arg).
                                  For particle, forces/update counter pairs are merged into
                                  a single side-by-side figure.
  2. scaling_lines/               Line plots: counter vs particle N, one line per
                                  (compiler, variant), one PNG per (counter, opt).
                                  Particle workload only.
  3. effect_forest/               Forest plots: bootstrap CI of (variant - baseline)
                                  per cell, one PNG per (workload, counter).
                                  Baseline = aos for particle, row_major for matrix.
  4. timing_overview/             Wall-time bars: real_time per variant, all opts side-by-side.
  5. compiler_delta/              GCC vs Clang comparison: grouped bars per variant,
                                  one panel per opt level, one PNG per (workload, bench_arg).

Usage:
    python3 plot_all.py <master_csv> [-o outdir]

Requires: pandas, matplotlib. Seaborn is used if available for nicer styling
but is not required.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

try:
    import pandas as pd
except ImportError:
    print("[ERROR] pandas required. Install: pip install pandas matplotlib", file=sys.stderr)
    sys.exit(1)

try:
    import matplotlib
    matplotlib.use("Agg")  # no display required
    import matplotlib.pyplot as plt
except ImportError:
    print("[ERROR] matplotlib required. Install: pip install matplotlib", file=sys.stderr)
    sys.exit(1)

# Optional, used only for nicer color palettes.
try:
    import seaborn as sns          # noqa: F401
    _HAS_SEABORN = True
except ImportError:
    _HAS_SEABORN = False


_BASELINE = {
    "particle": "aos",
    "matrix": "row_major",
}

# Counters of headline interest. Anything matching any of these substrings
# becomes a target for plot families 1 and 2. Keep this small — the master
# CSV has dozens of counters and we don't want to flood the figures dir.
_HEADLINE_COUNTER_PATTERNS = (
    "real_time",                 # timing
    "llc_misses",                # main thesis counter
    "llc_hit_rate",              # derived
    "ipc",                       # cycles efficiency
    "l1_misses",                 # spatial locality
    "dTLB-load-misses",          # Phase 2 TLB
    "stalled-cycles-backend",    # Phase 2 stalls
)

# For particle, these base names have both _forces and _update variants.
# They are merged into a single side-by-side figure.
_FORCES_UPDATE_BASES = ("llc_misses", "llc_hit_rate", "ipc", "l1_misses")

_PALETTE = ["#3a7ab3", "#e07b39", "#4aab6d", "#9b59b6", "#c0392b"]


def _is_headline(counter: str) -> bool:
    return any(p in counter for p in _HEADLINE_COUNTER_PATTERNS)


def _safe(s: str) -> str:
    return "".join(c if c.isalnum() or c in "._-" else "_" for c in s)


def _ensure_dir(p: Path) -> Path:
    p.mkdir(parents=True, exist_ok=True)
    return p


def _yerr_from_ci(df: pd.DataFrame) -> List[List[float]]:
    lower = (df["mean"] - df["ci95_lo"]).clip(lower=0).tolist()
    upper = (df["ci95_hi"] - df["mean"]).clip(lower=0).tolist()
    return [lower, upper]


def _draw_grouped_bars(ax, cell: pd.DataFrame, variants: list, compilers: list,
                       comp_colors: dict, bar_width: float) -> None:
    """Grouped bars: x = variant index, adjacent bars per compiler with CI error bars."""
    x = list(range(len(variants)))
    for ci, compiler in enumerate(compilers):
        cc = cell[cell["compiler"] == compiler]
        offsets = [v + (ci - (len(compilers) - 1) / 2) * bar_width for v in x]
        means, errs_lo, errs_hi = [], [], []
        for v in variants:
            row = cc[cc["variant"] == v]
            if row.empty:
                means.append(0); errs_lo.append(0); errs_hi.append(0)
            else:
                m = float(row["mean"].iloc[0])
                means.append(m)
                errs_lo.append(max(0.0, m - float(row["ci95_lo"].iloc[0])))
                errs_hi.append(max(0.0, float(row["ci95_hi"].iloc[0]) - m))
        ax.bar(offsets, means, width=bar_width,
               yerr=[errs_lo, errs_hi], capsize=2,
               color=comp_colors[compiler], edgecolor="black", linewidth=0.3,
               label=compiler)
    ax.set_xticks(x)
    ax.set_xticklabels(variants, rotation=20, fontsize=7)
    ax.tick_params(axis="y", labelsize=7)
    ax.grid(True, axis="y", linestyle=":", alpha=0.4)


def _draw_bars(ax, cell: pd.DataFrame, counter: str, title: str) -> None:
    cell = cell.sort_values("variant")
    xs = list(cell["variant"])
    ys = list(cell["mean"])
    yerr = _yerr_from_ci(cell)
    colors = [_PALETTE[i % len(_PALETTE)] for i in range(len(xs))]
    ax.bar(xs, ys, yerr=yerr, capsize=3, color=colors, edgecolor="white", linewidth=0.4)
    ax.set_title(title, fontsize=9)
    ax.tick_params(axis="x", labelrotation=20, labelsize=8)


# ── Plot 1: layout bars ────────────────────────────────────────────────────────

def _render_layout_bars_single(g: pd.DataFrame, workload: str, counter: str,
                                bench_arg: str, outdir: Path) -> None:
    compilers = sorted(g["compiler"].unique())
    opts = sorted(g["opt"].unique())
    fig, axes = plt.subplots(
        len(compilers), len(opts),
        figsize=(4 * len(opts), 3 * len(compilers)),
        squeeze=False, sharey=True,
    )
    for i, compiler in enumerate(compilers):
        for j, opt in enumerate(opts):
            ax = axes[i][j]
            cell = g[(g["compiler"] == compiler) & (g["opt"] == opt)]
            if cell.empty:
                ax.set_visible(False)
                continue
            _draw_bars(ax, cell, counter, f"{compiler} {opt}")
            if i == len(compilers) - 1:
                ax.set_xlabel("variant")
            if j == 0:
                ax.set_ylabel(counter)
    bench_tag = f" (N={bench_arg})" if bench_arg else ""
    fig.suptitle(f"{workload}: {counter}{bench_tag}", fontsize=11)
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    target = _ensure_dir(outdir / "layout_bars") / _safe(
        f"{workload}_{counter}_{bench_arg or 'na'}.png"
    )
    fig.savefig(target, dpi=120)
    plt.close(fig)


def _render_layout_bars_merged(gf: pd.DataFrame, gu: pd.DataFrame,
                                workload: str, base: str,
                                bench_arg: str, outdir: Path) -> None:
    """Side-by-side forces|update figure for particle paired counters."""
    compilers = sorted(gf["compiler"].unique())
    opts = sorted(gf["opt"].unique())
    counter_f = f"{base}_forces"
    counter_u = f"{base}_update"
    fig, axes = plt.subplots(
        len(compilers), len(opts) * 2,
        figsize=(4 * len(opts) * 2, 3 * len(compilers)),
        squeeze=False,
    )
    for i, compiler in enumerate(compilers):
        for j, opt in enumerate(opts):
            for k, (grp, cname) in enumerate([(gf, counter_f), (gu, counter_u)]):
                ax = axes[i][j * 2 + k]
                cell = grp[(grp["compiler"] == compiler) & (grp["opt"] == opt)]
                if cell.empty:
                    ax.set_visible(False)
                    continue
                _draw_bars(ax, cell, cname, f"{compiler} {opt} — {cname.split('_')[-1]}")
                if i == len(compilers) - 1:
                    ax.set_xlabel("variant")
                if j == 0 and k == 0:
                    ax.set_ylabel(base)
    bench_tag = f" (N={bench_arg})" if bench_arg else ""
    fig.suptitle(f"{workload}: {base} forces vs update{bench_tag}", fontsize=11)
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    target = _ensure_dir(outdir / "layout_bars") / _safe(
        f"{workload}_{base}_forces_update_{bench_arg or 'na'}.png"
    )
    fig.savefig(target, dpi=120)
    plt.close(fig)


def plot_layout_bars(df: pd.DataFrame, outdir: Path) -> int:
    sub = df[df["counter"].apply(_is_headline)].copy()
    if sub.empty:
        return 0

    n_plots = 0
    emitted_merged: set = set()

    for (workload, counter, bench_arg), g in sub.groupby(["workload", "counter", "bench_arg"]):
        if g["mean"].abs().sum() == 0:
            continue
        if not g["compiler"].nunique() or not g["opt"].nunique():
            continue

        # For particle paired counters, emit one merged figure instead of two separate.
        if workload == "particle":
            for base in _FORCES_UPDATE_BASES:
                if counter == f"{base}_forces":
                    key = (workload, base, bench_arg)
                    if key in emitted_merged:
                        break
                    # Find the matching _update group.
                    gu = sub[(sub["workload"] == workload)
                             & (sub["counter"] == f"{base}_update")
                             & (sub["bench_arg"] == bench_arg)]
                    if not gu.empty:
                        _render_layout_bars_merged(g, gu, workload, base, bench_arg, outdir)
                        emitted_merged.add(key)
                        n_plots += 1
                        break
                    # No matching _update — fall through to single render.
                elif counter == f"{base}_update":
                    # Already handled by the _forces branch.
                    key = (workload, base, bench_arg)
                    if key in emitted_merged:
                        break
                    # _forces not seen yet — render single for now; will be merged if
                    # _forces appears later. Since groupby is sorted, _forces comes first,
                    # so this branch only fires when _forces is absent.
                    break

        _render_layout_bars_single(g, workload, counter, bench_arg, outdir)
        n_plots += 1

    return n_plots


# ── Plot 2: scaling lines (particle N=512/2048/8192) ───────────────────────────

def plot_scaling_lines(df: pd.DataFrame, outdir: Path) -> int:
    sub = df[
        (df["workload"] == "particle")
        & (df["bench_arg"] != "")
        & (df["counter"].apply(_is_headline))
    ].copy()
    if sub.empty:
        return 0

    sub["bench_arg_int"] = pd.to_numeric(sub["bench_arg"], errors="coerce")
    sub = sub.dropna(subset=["bench_arg_int"])
    sub["bench_arg_int"] = sub["bench_arg_int"].astype(int)

    n_plots = 0
    for (counter, opt), g in sub.groupby(["counter", "opt"]):
        if g["mean"].abs().sum() == 0:
            continue
        fig, ax = plt.subplots(figsize=(7, 4))
        for idx, ((compiler, variant), gg) in enumerate(g.groupby(["compiler", "variant"])):
            gg = gg.sort_values("bench_arg_int")
            ls = "-" if compiler == "gcc" else "--"
            ax.errorbar(
                gg["bench_arg_int"], gg["mean"],
                yerr=_yerr_from_ci(gg),
                marker="o", capsize=3, linestyle=ls,
                color=_PALETTE[idx % len(_PALETTE)],
                label=f"{compiler}/{variant}",
            )
        ax.set_xscale("log", base=2)
        ax.set_xlabel("particle count N")
        ax.set_ylabel(counter)
        ax.set_title(f"particle: {counter} vs N ({opt})")
        ax.legend(fontsize=8, loc="best", ncol=2)
        ax.grid(True, which="both", linestyle=":", alpha=0.4)
        fig.tight_layout()

        target = _ensure_dir(outdir / "scaling_lines") / _safe(
            f"particle_{counter}_{opt}.png"
        )
        fig.savefig(target, dpi=120)
        plt.close(fig)
        n_plots += 1
    return n_plots


# ── Plot 3: forest of (variant - baseline) effect sizes ────────────────────────

def plot_effect_forest(df: pd.DataFrame, outdir: Path) -> int:
    sub = df[df["counter"].apply(_is_headline)].copy()
    if sub.empty:
        return 0

    n_plots = 0
    for (workload, counter), g in sub.groupby(["workload", "counter"]):
        baseline = _BASELINE.get(workload)
        if not baseline:
            continue
        keys = ["compiler", "opt", "bench_arg"]
        rows = []
        for k, gg in g.groupby(keys):
            base_row = gg[gg["variant"] == baseline]
            if base_row.empty:
                continue
            base_mean = base_row["mean"].iloc[0]
            for _, row in gg.iterrows():
                if row["variant"] == baseline or base_mean == 0:
                    continue
                diff = row["mean"] - base_mean
                rel = diff / abs(base_mean)
                half = max(row["ci95_hi"] - row["mean"], row["mean"] - row["ci95_lo"])
                rel_half = half / abs(base_mean) if base_mean != 0 else 0.0
                label = f"{row['compiler']}/{row['opt']}/{row['variant']}"
                if row["bench_arg"]:
                    label += f"/N={row['bench_arg']}"
                rows.append({"label": label, "rel_diff": rel, "ci_half": rel_half})
        if not rows:
            continue
        rows.sort(key=lambda r: r["rel_diff"])

        fig, ax = plt.subplots(figsize=(8, max(3, 0.25 * len(rows))))
        ys = list(range(len(rows)))
        rel = [r["rel_diff"] for r in rows]
        err = [r["ci_half"] for r in rows]
        ax.errorbar(rel, ys, xerr=err, fmt="o", capsize=3, color=_PALETTE[0])
        ax.axvline(0, color="black", linewidth=0.8)
        ax.set_yticks(ys)
        ax.set_yticklabels([r["label"] for r in rows], fontsize=7)
        ax.set_xlabel(f"(variant − {baseline}) / {baseline}   (negative = better than baseline)")
        ax.set_title(f"{workload}: relative effect on {counter} vs {baseline}")
        ax.grid(True, axis="x", linestyle=":", alpha=0.4)
        fig.tight_layout()

        target = _ensure_dir(outdir / "effect_forest") / _safe(
            f"{workload}_{counter}.png"
        )
        fig.savefig(target, dpi=120)
        plt.close(fig)
        n_plots += 1
    return n_plots


# ── Plot 4: timing overview ────────────────────────────────────────────────────

def plot_timing_overview(df: pd.DataFrame, outdir: Path) -> int:
    sub = df[(df["counter"] == "real_time") & (df["phase"] == "counter")].copy()
    if sub.empty:
        return 0

    n_plots = 0
    for (workload, bench_arg), g in sub.groupby(["workload", "bench_arg"]):
        if g["mean"].abs().sum() == 0:
            continue
        compilers = sorted(g["compiler"].unique())
        opts = sorted(g["opt"].unique())
        variants = sorted(g["variant"].unique())
        if not (compilers and opts and variants):
            continue

        fig, ax = plt.subplots(figsize=(2 + 1.5 * len(opts) * len(compilers), 4))
        x_labels, x_pos, bar_means = [], [], []
        bar_errs_lo, bar_errs_hi, bar_colors = [], [], []
        var_to_color = {v: _PALETTE[i % len(_PALETTE)] for i, v in enumerate(variants)}

        idx = 0
        group_centers = []
        for compiler in compilers:
            for opt in opts:
                cell = g[(g["compiler"] == compiler) & (g["opt"] == opt)]
                if cell.empty:
                    continue
                start = idx
                for v in variants:
                    sub2 = cell[cell["variant"] == v]
                    if sub2.empty:
                        continue
                    bar_means.append(float(sub2["mean"].iloc[0]))
                    bar_errs_lo.append(float(sub2["mean"].iloc[0] - sub2["ci95_lo"].iloc[0]))
                    bar_errs_hi.append(float(sub2["ci95_hi"].iloc[0] - sub2["mean"].iloc[0]))
                    x_labels.append(v)
                    x_pos.append(idx)
                    bar_colors.append(var_to_color[v])
                    idx += 1
                if idx > start:
                    group_centers.append(((start + idx - 1) / 2, f"{compiler}/{opt}"))
                idx += 1

        if not bar_means:
            continue

        ax.bar(x_pos, bar_means, yerr=[bar_errs_lo, bar_errs_hi],
               capsize=3, color=bar_colors, edgecolor="black", linewidth=0.4)
        ax.set_xticks(x_pos)
        ax.set_xticklabels(x_labels, rotation=30, fontsize=8)
        ax.set_ylabel("real_time (ms)")
        sec_ax = ax.secondary_xaxis("top")
        sec_ax.set_xticks([c[0] for c in group_centers])
        sec_ax.set_xticklabels([c[1] for c in group_centers], fontsize=8)
        sec_ax.tick_params(axis="x", direction="in", pad=2)
        bench_tag = f" (N={bench_arg})" if bench_arg else ""
        ax.set_title(f"{workload} timing overview{bench_tag}")
        fig.tight_layout()

        target = _ensure_dir(outdir / "timing_overview") / _safe(
            f"{workload}_{bench_arg or 'na'}.png"
        )
        fig.savefig(target, dpi=120)
        plt.close(fig)
        n_plots += 1
    return n_plots


# ── Plot 5: compiler delta — GCC vs Clang side-by-side ────────────────────────

def plot_compiler_delta(df: pd.DataFrame, outdir: Path) -> int:
    sub = df[(df["counter"] == "real_time") & (df["phase"] == "counter")].copy()
    if sub.empty:
        return 0
    if sub["compiler"].nunique() < 2:
        return 0

    n_plots = 0
    for (workload, bench_arg), g in sub.groupby(["workload", "bench_arg"]):
        if g["mean"].abs().sum() == 0:
            continue
        opts = sorted(g["opt"].unique())
        variants = sorted(g["variant"].unique())
        compilers = sorted(g["compiler"].unique())
        if len(compilers) < 2 or not opts or not variants:
            continue

        fig, axes = plt.subplots(
            1, len(opts),
            figsize=(4 * len(opts), 4),
            squeeze=False, sharey=True,
        )
        compiler_colors = {c: _PALETTE[i] for i, c in enumerate(compilers)}
        bar_width = 0.8 / len(compilers)

        for j, opt in enumerate(opts):
            ax = axes[0][j]
            cell = g[g["opt"] == opt]
            x_ticks = list(range(len(variants)))
            for ci, compiler in enumerate(compilers):
                cc = cell[cell["compiler"] == compiler]
                offsets = [x + (ci - (len(compilers) - 1) / 2) * bar_width for x in x_ticks]
                means, errs_lo, errs_hi = [], [], []
                for v in variants:
                    row = cc[cc["variant"] == v]
                    if row.empty:
                        means.append(0); errs_lo.append(0); errs_hi.append(0)
                    else:
                        m = float(row["mean"].iloc[0])
                        means.append(m)
                        errs_lo.append(float(m - row["ci95_lo"].iloc[0]))
                        errs_hi.append(float(row["ci95_hi"].iloc[0] - m))
                ax.bar(offsets, means, width=bar_width,
                       yerr=[errs_lo, errs_hi], capsize=2,
                       color=compiler_colors[compiler], edgecolor="black",
                       linewidth=0.4, label=compiler)
            ax.set_xticks(x_ticks)
            ax.set_xticklabels(variants, rotation=20, fontsize=8)
            ax.set_title(opt, fontsize=9)
            if j == 0:
                ax.set_ylabel("real_time (ms)")
                ax.legend(fontsize=8)
            ax.grid(True, axis="y", linestyle=":", alpha=0.4)

        bench_tag = f" (N={bench_arg})" if bench_arg else ""
        fig.suptitle(f"{workload}: GCC vs Clang timing{bench_tag}", fontsize=11)
        fig.tight_layout(rect=(0, 0, 1, 0.96))

        target = _ensure_dir(outdir / "compiler_delta") / _safe(
            f"{workload}_{bench_arg or 'na'}.png"
        )
        fig.savefig(target, dpi=120)
        plt.close(fig)
        n_plots += 1
    return n_plots


# ── Plot 6: merged overview — all N / compiler / opt in one figure ────────────

def plot_merged(df: pd.DataFrame, outdir: Path) -> int:
    """
    One PNG per (workload, counter) combining every compiler/opt/N cell into a
    single panel grid — intended to be dropped directly into a thesis chapter.

    Particle  — rows = bench_arg (N values), cols = opt levels.
                Each panel: grouped bars, one cluster per variant, one bar per compiler.

    Matrix    — rows = compiler, cols = opt.
                Each panel: simple bars per variant (no N dimension exists).

    Scoped to phase="counter" to prevent real_time measurements from the perf-phase
    binaries (single rep, different binary) being mixed with counter-phase data.
    """
    sub = df[
        df["counter"].apply(_is_headline) & (df["phase"] == "counter")
    ].copy()
    if sub.empty:
        return 0

    n_plots = 0
    for (workload, counter), g in sub.groupby(["workload", "counter"]):
        if g["mean"].abs().sum() == 0:
            continue

        compilers  = sorted(g["compiler"].unique())
        opts       = sorted(g["opt"].unique())
        variants   = sorted(g["variant"].unique())
        bench_args = [b for b in sorted(g["bench_arg"].unique()) if b != ""]

        comp_colors = {c: _PALETTE[i % len(_PALETTE)] for i, c in enumerate(compilers)}
        bar_width   = 0.8 / max(len(compilers), 1)

        if workload == "particle" and bench_args:
            nrows, ncols = len(bench_args), len(opts)
            fig, axes = plt.subplots(
                nrows, ncols,
                figsize=(3.5 * ncols, 3 * nrows),
                squeeze=False,
            )
            for i, bench_arg in enumerate(bench_args):
                for j, opt in enumerate(opts):
                    ax = axes[i][j]
                    cell = g[(g["bench_arg"] == bench_arg) & (g["opt"] == opt)]
                    if cell.empty:
                        ax.set_visible(False)
                        continue
                    _draw_grouped_bars(ax, cell, variants, compilers, comp_colors, bar_width)
                    ax.set_title(f"{opt} · N={bench_arg}", fontsize=8)
                    if j == 0:
                        ax.set_ylabel(counter, fontsize=8)

            handles = [plt.Rectangle((0, 0), 1, 1, color=comp_colors[c]) for c in compilers]
            fig.legend(handles, compilers, loc="lower center",
                       ncol=len(compilers), fontsize=9, bbox_to_anchor=(0.5, 0))
            fig.suptitle(f"particle: {counter}", fontsize=11)
            fig.tight_layout(rect=(0, 0.05, 1, 0.97))

        else:
            # Matrix — rows = compiler, cols = opt, no N dimension.
            nrows, ncols = len(compilers), len(opts)
            var_colors = {v: _PALETTE[i % len(_PALETTE)] for i, v in enumerate(variants)}
            fig, axes = plt.subplots(
                nrows, ncols,
                figsize=(3.5 * ncols, 3 * nrows),
                squeeze=False, sharey=True,
            )
            for i, compiler in enumerate(compilers):
                for j, opt in enumerate(opts):
                    ax = axes[i][j]
                    cell = g[(g["compiler"] == compiler) & (g["opt"] == opt)]
                    if cell.empty:
                        ax.set_visible(False)
                        continue
                    x = list(range(len(variants)))
                    means, errs_lo, errs_hi, colors = [], [], [], []
                    for v in variants:
                        row = cell[cell["variant"] == v]
                        if row.empty:
                            means.append(0); errs_lo.append(0); errs_hi.append(0)
                        else:
                            m = float(row["mean"].iloc[0])
                            means.append(m)
                            errs_lo.append(max(0.0, m - float(row["ci95_lo"].iloc[0])))
                            errs_hi.append(max(0.0, float(row["ci95_hi"].iloc[0]) - m))
                        colors.append(var_colors[v])
                    ax.bar(x, means, yerr=[errs_lo, errs_hi], capsize=2,
                           color=colors, edgecolor="black", linewidth=0.4)
                    ax.set_xticks(x)
                    ax.set_xticklabels(variants, rotation=20, fontsize=7)
                    ax.set_title(f"{compiler} · {opt}", fontsize=8)
                    if j == 0:
                        ax.set_ylabel(counter, fontsize=8)
                    ax.grid(True, axis="y", linestyle=":", alpha=0.4)
                    ax.tick_params(axis="y", labelsize=7)

            fig.suptitle(f"matrix: {counter}", fontsize=11)
            fig.tight_layout(rect=(0, 0, 1, 0.97))

        target = _ensure_dir(outdir / "merged") / _safe(f"{workload}_{counter}.png")
        fig.savefig(target, dpi=120)
        plt.close(fig)
        n_plots += 1

    return n_plots


# ── Driver ────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("master_csv", type=Path)
    parser.add_argument("-o", "--outdir", type=Path, default=None,
                        help="Output directory (default: <master_csv parent>/figures)")
    args = parser.parse_args()

    if not args.master_csv.is_file():
        print(f"[ERROR] No such file: {args.master_csv}", file=sys.stderr)
        return 1

    outdir = args.outdir or (args.master_csv.parent / "figures")
    _ensure_dir(outdir)

    df = pd.read_csv(args.master_csv)
    if df.empty:
        print("[WARN] master.csv is empty", file=sys.stderr)
        return 0

    df["bench_arg"] = (
        df["bench_arg"]
        .fillna("")
        .astype(str)
        .str.replace(r"\.0$", "", regex=True)
    )
    df["compiler"] = df["compiler"].fillna("unknown")

    n1 = plot_layout_bars(df, outdir);      print(f"[INFO] layout_bars      {n1} plots")
    n2 = plot_scaling_lines(df, outdir);    print(f"[INFO] scaling_lines    {n2} plots")
    n3 = plot_effect_forest(df, outdir);    print(f"[INFO] effect_forest    {n3} plots")
    n4 = plot_timing_overview(df, outdir);  print(f"[INFO] timing_overview  {n4} plots")
    n5 = plot_compiler_delta(df, outdir);   print(f"[INFO] compiler_delta   {n5} plots")
    n6 = plot_merged(df, outdir);           print(f"[INFO] merged           {n6} plots")
    total = n1 + n2 + n3 + n4 + n5 + n6
    print(f"[INFO] Total: {total} plots → {outdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
