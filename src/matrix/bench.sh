#!/usr/bin/env bash
# Matrix benchmark runner.
#
# Usage:
#   ./bench.sh [COMPILER] [OPT] [MODE] [INVOCATIONS]
#   COMPILER    gcc | clang                    (default: clang)
#   OPT         O2 | O3 | O3_native            (default: O3)
#   MODE        counter | perf | sampling       (default: counter)
#               counter  = Pass A: in-process PerfCounterGroup, no perf stat
#               perf     = Pass B: three split perf stat passes (cache/TLB/stalls)
#               sampling = Pass C: perf record + annotate (source-level LLC miss attribution)
#   INVOCATIONS independent runs per variant — ignored for sampling (always 1) (default: 1)
#
# Build dir:  build/{compiler}/matrix/{variant}/{OPT}/{counter,perf}/
# Results:   results/{compiler}/matrix/{variant}/{OPT}/{MODE}/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${REPO_ROOT}/scripts/bench_common.sh"

COMPILER="${1:-clang}"
OPT="${2:-O3}"
MODE="${3:-counter}"
INVOCATIONS="${4:-1}"
BUILD_ROOT="${REPO_ROOT}/build"

if [[ "$COMPILER" != "gcc" && "$COMPILER" != "clang" ]]; then
    echo "[ERROR] COMPILER must be 'gcc' or 'clang', got: ${COMPILER}" >&2
    exit 1
fi

if [[ "$MODE" != "counter" && "$MODE" != "perf" && "$MODE" != "sampling" ]]; then
    echo "[ERROR] MODE must be 'counter', 'perf', or 'sampling', got: ${MODE}" >&2
    exit 1
fi

# sampling uses the perf binary (DISABLE_PERF_COUNTER=1) — no in-process counter fd conflict.
bin_mode="$MODE"
[[ "$MODE" == "sampling" ]] && bin_mode="perf"

run_for_mode() {
    local binary="$1"
    local result_dir="$2"
    case "$MODE" in
        counter)  run_bench_counter  "$binary" "$result_dir" "$INVOCATIONS" ;;
        perf)     run_bench_perf_all "$binary" "$result_dir" "$INVOCATIONS" ;;
        sampling) run_bench_sampling "$binary" "$result_dir" ;;
    esac
}

VARIANTS=(row_major tile_contiguous)

for variant in "${VARIANTS[@]}"; do
    binary="${BUILD_ROOT}/${COMPILER}/matrix/${variant}/${OPT}/${bin_mode}/matrix_${variant}"
    result_dir="${REPO_ROOT}/results/${COMPILER}/matrix/${variant}/${OPT}/${MODE}"

    if [[ ! -x "$binary" ]]; then
        echo "[SKIP] ${binary} not found" >&2
        echo "[SKIP] Build with: make build COMPILER=${COMPILER} WORKLOAD=matrix VARIANT=${variant} OPT=${OPT} MODE=${bin_mode}" >&2
        continue
    fi

    echo "════════════════════════════════════════════════"
    echo "  Matrix / ${COMPILER} / ${variant} / ${OPT} / ${MODE}"
    echo "════════════════════════════════════════════════"
    run_for_mode "$binary" "$result_dir"
    echo ""
done
