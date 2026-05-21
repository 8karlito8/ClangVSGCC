"""
Parse `perf stat --field-separator=,` output.

Format (per event line, with -r N):
    count,unit,event,run_time_ns,run_pct,metric_value,metric_unit,stddev_pct
Lines beginning with '#' or blank lines are headers/comments.
The 'count' field may be '<not counted>', '<not supported>', or a numeric string
(possibly with thousands separators on some perf versions, though
--field-separator=, normally avoids them).

We extract:
  event (str)
  count (float, NaN if not counted)
  stddev_pct (float, NaN if absent)

Tolerant of perf version differences: we parse positionally but check field
counts.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import List


@dataclass
class PerfStatRow:
    event: str
    count: float           # NaN if not counted
    stddev_pct: float      # NaN if absent

    def is_valid(self) -> bool:
        return not math.isnan(self.count)


def _to_float(s: str) -> float:
    s = s.strip().replace(",", "")
    if not s or s.startswith("<") or s.endswith(">"):
        return float("nan")
    try:
        return float(s)
    except ValueError:
        return float("nan")


def parse_perf_stat_csv(path: Path) -> List[PerfStatRow]:
    """Parse a perf stat CSV file into a list of PerfStatRow.

    Skips comment lines (#…) and blank lines. Tolerates trailing/leading
    whitespace and missing optional fields.
    """
    rows: List[PerfStatRow] = []
    if not path.exists():
        return rows

    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue

            # perf stat --field-separator=, splits on comma. With -r N, format is:
            #   count,unit,event,run_time_ns,run_pct,metric_value,metric_unit,variance_pct
            # The variance percentage (the +-X.XX%) is the last field.
            parts = line.split(",")
            if len(parts) < 3:
                continue

            count = _to_float(parts[0])
            event = parts[2].strip()
            stddev_pct = float("nan")

            # Last field, if present and contains a number, is the variance percentage.
            if len(parts) >= 8:
                stddev_pct = _to_float(parts[7])
            elif len(parts) >= 6:
                # Some perf versions put variance earlier when no metric is present.
                stddev_pct = _to_float(parts[-1])

            if event:
                rows.append(PerfStatRow(event=event, count=count, stddev_pct=stddev_pct))

    return rows


def parse_perf_report_csv(path: Path, top_n: int = 20) -> List[dict]:
    """Parse the output of `perf report --stdio -F overhead,sample,symbol,srcfile,srcline`.

    The output is space-padded columns rather than CSV. We tolerate any whitespace,
    skip comment lines, and return the top_n highest-overhead entries with
    overhead (%), sample count, symbol, source file, source line.
    """
    rows: List[dict] = []
    if not path.exists():
        return rows

    pattern = re.compile(
        r"^\s*([\d.]+)%\s+(\d+)\s+(\S+)\s*(\S+)?\s*(\d+)?\s*$"
    )

    with path.open() as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            m = pattern.match(line)
            if not m:
                continue
            overhead_pct, samples, symbol, srcfile, srcline = m.groups()
            rows.append({
                "overhead_pct": float(overhead_pct),
                "samples": int(samples),
                "symbol": symbol,
                "srcfile": srcfile or "",
                "srcline": int(srcline) if srcline else -1,
            })
            if len(rows) >= top_n:
                break
    return rows
