#!/usr/bin/env bash
# Top-level walk-away orchestrator.
#
# Requires the system to already be in benchmark state. Run once before this:
#   make system-setup
#
# Sequence:
#   1. Env validation  — checks governor, turbo, isolcpus, HT sibling, deps.
#                        Exits immediately if anything is wrong — no sudo, no fixes.
#   2. Build matrix    — compiler × opt × workload × variant × mode
#   3. Run benchmarks  — workloads run sequentially: particle first, then matrix
#                        matrix is skipped if any particle cell failed
#   4. Aggregate       — aggregate_all.py → results/master.csv
#   5. Plot            — plot_all.py → results/figures/
#
# Usage:
#   make system-setup   # once per boot (requires sudo, sets governor/turbo/watchdog)
#   make run-all        # walk away
#
# Matrix dimensions (override via env):
#   COMPILERS       default: "gcc clang"
#   OPTS            default: "O2 O3 O3_native"
#   PARTICLE_VAR    default: "aos soa aligned"
#   MATRIX_VAR      default: "row_major tile_contiguous"
#   PHASES          default: "counter perf sampling"
#   INVOCATIONS     default: 5
#   BENCH_TIMEOUT   default: 1800 s per invocation
#
# Skip pieces:
#   SKIP_BUILD=1       skip meson builds
#   SKIP_RUN=1         skip benchmark execution (only re-aggregate + plot)
#   SKIP_AGGREGATE=1   skip aggregate_all.py
#   SKIP_PLOT=1        skip plot_all.py
#
# Dev overrides (taint results — mark output as invalid):
#   BENCH_CPU=<N>              pin to a specific CPU (default: auto-selected last online CPU)
#   BENCH_SKIP_TURBO_CHECK=1  skip turbo check on non-Intel/non-AMD systems

# NOT using set -e — one bad cell must not abort the whole run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/bench_common.sh"
set +e   # bench_common.sh sets -e; restore intended no-exit-on-error for per-cell isolation

# ── Matrix configuration ─────────────────────────────────────────────────────
# Override the benchmark CPU (optional — auto-selected if not set):
#   BENCH_CPU=<N> make run-all
# Skip turbo check on non-Intel/non-AMD systems (taints results):
#   BENCH_SKIP_TURBO_CHECK=1 make run-all

COMPILERS="${COMPILERS:-gcc clang}"
OPTS="${OPTS:-O2 O3 O3_native}"
PARTICLE_VAR="${PARTICLE_VAR:-aos soa aligned}"
MATRIX_VAR="${MATRIX_VAR:-row_major tile_contiguous}"
PHASES="${PHASES:-counter perf sampling}"
INVOCATIONS="${INVOCATIONS:-3}"
export BENCH_TIMEOUT="${BENCH_TIMEOUT:-1800}"

BUILD_ROOT="${REPO_ROOT}/build"
RESULTS_ROOT="${REPO_ROOT}/results"
LOG_DIR="${RESULTS_ROOT}/_logs"
ORCH_LOG="${LOG_DIR}/orchestrator.log"

mkdir -p "$LOG_DIR"
: > "$ORCH_LOG"

# ── Failure registry ──────────────────────────────────────────────────────────
declare -A FAILED=()
fail_cell() { FAILED["$1"]="$2"; }
workload_failed() {
    local wl="$1"
    local k
    for k in "${!FAILED[@]}"; do
        [[ "$k" == *"/${wl}/"* || "$k" == *"/${wl}" ]] && return 0
    done
    return 1
}

ts_now() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { echo "[$(ts_now)] $*" | tee -a "$ORCH_LOG"; }
warn() { echo "[$(ts_now)] [WARN] $*" | tee -a "$ORCH_LOG" >&2; }
err()  { echo "[$(ts_now)] [ERROR] $*" | tee -a "$ORCH_LOG" >&2; }

# ── Workload variant lookup ───────────────────────────────────────────────────
variants_for() {
    case "$1" in
        particle) echo $PARTICLE_VAR ;;
        matrix)   echo $MATRIX_VAR ;;
        *)        echo "" ;;
    esac
}

bin_mode_for() {
    case "$1" in
        counter)  echo "counter" ;;
        perf)     echo "perf" ;;
        sampling) echo "perf" ;;
        *)        echo "$1" ;;
    esac
}

# ── Build a single cell ───────────────────────────────────────────────────────
# Args: compiler opt workload variant mode
build_cell() {
    local compiler="$1" opt="$2" workload="$3" variant="$4" mode="$5"
    local cell_log="${LOG_DIR}/build_${compiler}_${opt}_${workload}_${variant}_${mode}.log"
    local builddir="${BUILD_ROOT}/${compiler}/${workload}/${variant}/${opt}/${mode}"

    local cflags
    case "$opt" in
        O2)        cflags="-O2 -g" ;;
        O3)        cflags="-O3 -g" ;;
        O3_native) cflags="-O3 -march=native -g" ;;
        *)         cflags="-O2 -g" ;;
    esac

    local disable_perf="false"
    [[ "$mode" == "perf" ]] && disable_perf="true"

    local cxx
    case "$compiler" in
        gcc)   cxx="g++" ;;
        clang) cxx="clang++" ;;
        *)     cxx="$compiler" ;;
    esac

    {
        echo "═══ build ${cxx} ${cflags} workload=${workload} variant=${variant} mode=${mode} ═══"
        rm -rf "$builddir"
        CXX="$cxx" CXXFLAGS="$cflags" meson setup "$builddir" \
            -Dworkload="$workload" \
            -Dvariant="$variant" \
            -Ddisable_perf_counter="$disable_perf" \
            -Dbuildtype=plain
        meson compile -C "$builddir"
    } &> "$cell_log"

    return $?
}

# ── Run a single cell ─────────────────────────────────────────────────────────
# Args: compiler opt workload variant phase
run_cell() {
    local compiler="$1" opt="$2" workload="$3" variant="$4" phase="$5"
    local mode; mode=$(bin_mode_for "$phase")
    local cell_log="${LOG_DIR}/run_${compiler}_${opt}_${workload}_${variant}_${phase}.log"
    local builddir="${BUILD_ROOT}/${compiler}/${workload}/${variant}/${opt}/${mode}"
    local binary="${builddir}/${workload}_${variant}"
    local result_dir="${RESULTS_ROOT}/${compiler}/${workload}/${variant}/${opt}/${phase}"

    if [[ ! -x "$binary" ]]; then
        err "Missing binary: $binary"
        return 127
    fi

    mkdir -p "$result_dir"
    {
        echo "═══ run compiler=${compiler} opt=${opt} workload=${workload} variant=${variant} phase=${phase} ═══"
        case "$phase" in
            counter)  run_bench_counter  "$binary" "$result_dir" "$INVOCATIONS" ;;
            perf)     run_bench_perf_all "$binary" "$result_dir" "$INVOCATIONS" ;;
            sampling) run_bench_sampling "$binary" "$result_dir" ;;
            *)        echo "[ERROR] Unknown phase: $phase"; return 1 ;;
        esac
    } &>> "$cell_log"

    return $?
}

# ── Build + run a single workload ─────────────────────────────────────────────
# Returns the number of failed cells for this workload.
run_workload() {
    local workload="$1"
    local n_fail=0

    log "════════════════════════════════════════════════════════════"
    log "  Workload: ${workload}"
    log "════════════════════════════════════════════════════════════"

    # ── Build ────────────────────────────────────────────────────
    if [[ "${SKIP_BUILD:-0}" != "1" && "${SKIP_RUN:-0}" != "1" ]]; then
        log "  Building ${workload}…"
        for compiler in $COMPILERS; do
            for opt in $OPTS; do
                for variant in $(variants_for "$workload"); do
                    local needs_perf=0 needs_counter=0
                    local ph
                    for ph in $PHASES; do
                        local m; m=$(bin_mode_for "$ph")
                        [[ "$m" == "perf" ]]     && needs_perf=1
                        [[ "$m" == "counter" ]]  && needs_counter=1
                    done
                    for mode in $( \
                        [[ $needs_counter -eq 1 ]] && echo counter; \
                        [[ $needs_perf    -eq 1 ]] && echo perf); do
                        local key="${compiler}/${opt}/${workload}/${variant}/${mode}"
                        log "    build  $key"
                        if build_cell "$compiler" "$opt" "$workload" "$variant" "$mode"; then
                            : # ok
                        else
                            warn "    BUILD FAILED — ${LOG_DIR}/build_${compiler}_${opt}_${workload}_${variant}_${mode}.log"
                            fail_cell "build/$key" "build failed"
                            n_fail=$((n_fail + 1))
                        fi
                    done
                done
            done
        done
    fi

    # ── Run ──────────────────────────────────────────────────────
    if [[ "${SKIP_RUN:-0}" != "1" ]]; then
        log "  Running ${workload}…"
        for compiler in $COMPILERS; do
            for opt in $OPTS; do
                for variant in $(variants_for "$workload"); do
                    for phase in $PHASES; do
                        local key="${compiler}/${opt}/${workload}/${variant}/${phase}"
                        local m; m=$(bin_mode_for "$phase")
                        local bin="${BUILD_ROOT}/${compiler}/${workload}/${variant}/${opt}/${m}/${workload}_${variant}"
                        if [[ ! -x "$bin" ]]; then
                            warn "    skip   $key — binary missing"
                            fail_cell "skip/$key" "binary missing"
                            n_fail=$((n_fail + 1))
                            continue
                        fi
                        log "    run    $key"
                        if run_cell "$compiler" "$opt" "$workload" "$variant" "$phase"; then
                            : # ok
                        else
                            local rc=$?
                            warn "    RUN FAILED (rc=${rc}) — ${LOG_DIR}/run_${compiler}_${opt}_${workload}_${variant}_${phase}.log"
                            fail_cell "run/$key" "run failed (rc=${rc})"
                            n_fail=$((n_fail + 1))
                        fi
                    done
                done
            done
        done
    fi

    return "$n_fail"
}

# ── Main flow ─────────────────────────────────────────────────────────────────

log "════════════════════════════════════════════════════════════"
log "  Thesis benchmark orchestrator"
log "════════════════════════════════════════════════════════════"
log "Compilers : $COMPILERS"
log "Opts      : $OPTS"
log "Particle  : $PARTICLE_VAR"
log "Matrix    : $MATRIX_VAR"
log "Phases    : $PHASES"
log "Invoc/cell: $INVOCATIONS"
log "Timeout   : ${BENCH_TIMEOUT}s per invocation"
log ""

# ── 1. Environment validation ────────────────────────────────────────────────
# Checks governor, turbo, isolcpus, HT sibling, deps. No sudo. Exits on failure.
# If any check fails, run 'make system-setup' first (once per boot), then retry.
if [[ "${SKIP_RUN:-0}" != "1" ]]; then
    log "─── Environment validation ─────────────────────────────────"
    if ! BENCH_CPU=$(prepare_environment_once 2>> "$ORCH_LOG"); then
        err "Environment not ready — failing check:"
        grep -E '\[ERROR\]|\[WARN\]' "$ORCH_LOG" | tail -5 | while IFS= read -r line; do
            err "  $line"
        done
        err "Run 'make system-setup' first."
        err "If isolcpus= is not set: BENCH_ALLOW_NO_ISOLCPUS=1 make run-all (taints results)."
        exit 1
    fi
    log "Pinned CPU: $BENCH_CPU"
    export BENCH_SKIP_CHECKS=1
    export BENCH_CPU
    log ""
fi

# ── 2+3. Sequential workloads ─────────────────────────────────────────────────
particle_fails=0
matrix_fails=0

run_workload particle || particle_fails=$?

if [[ "$particle_fails" -eq 0 ]]; then
    run_workload matrix || matrix_fails=$?
else
    log ""
    warn "Particle had ${particle_fails} failure(s) — skipping matrix to avoid wasting time."
    warn "Fix particle failures, then re-run with SKIP_BUILD=1 SKIP_RUN=1 to aggregate existing results,"
    warn "or set PARTICLE_VAR='' MATRIX_VAR='row_major tile_contiguous' to run matrix only."
    log ""
fi

# ── 4. Aggregate ──────────────────────────────────────────────────────────────
if [[ "${SKIP_AGGREGATE:-0}" != "1" ]]; then
    log "─── Aggregating results ────────────────────────────────────"
    if (cd "${REPO_ROOT}/scripts" && uv run python aggregate_all.py "$RESULTS_ROOT" \
           -o "${RESULTS_ROOT}/master.csv") 2>&1 | tee -a "$ORCH_LOG"; then
        log "master CSV → ${RESULTS_ROOT}/master.csv"
    else
        err "aggregate_all.py failed"
        fail_cell "aggregate" "aggregate_all.py exit non-zero"
    fi
    log ""
fi

# ── 5. Plot ───────────────────────────────────────────────────────────────────
if [[ "${SKIP_PLOT:-0}" != "1" ]]; then
    log "─── Plotting ───────────────────────────────────────────────"
    if [[ -f "${RESULTS_ROOT}/master.csv" ]]; then
        if (cd "${REPO_ROOT}/scripts" && uv run python plot_all.py "${RESULTS_ROOT}/master.csv") 2>&1 | tee -a "$ORCH_LOG"; then
            log "figures → ${RESULTS_ROOT}/figures/"
        else
            err "plot_all.py failed"
            fail_cell "plot" "plot_all.py exit non-zero"
        fi
    else
        warn "skipping plots: ${RESULTS_ROOT}/master.csv does not exist"
    fi
    log ""
fi

# ── 6. Summary ────────────────────────────────────────────────────────────────
log "════════════════════════════════════════════════════════════"
log "  Summary"
log "════════════════════════════════════════════════════════════"
n_failed=${#FAILED[@]}
if [[ "$n_failed" -eq 0 ]]; then
    log "All cells succeeded."
    exit 0
else
    log "Failed cells: $n_failed"
    for k in "${!FAILED[@]}"; do
        log "  $k — ${FAILED[$k]}"
    done
    exit 1
fi
