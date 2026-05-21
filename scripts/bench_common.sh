#!/usr/bin/env bash
# Shared benchmark infrastructure: system setup, CPU isolation, perf stat wrapping.
#
# Source this file; do not execute directly.
# Requires: perf, taskset (util-linux), numactl, chrt (util-linux), timeout (coreutils).

set -euo pipefail

# ── perf stat event groups — split to stay within 4 PMU slots each ─────────────
# B1 — Cache locality: L1 and LLC miss rates
readonly PERF_EVENTS_B1="L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses"
# B2 — TLB pressure: page-walk overhead (page walks evict cache lines and inflate miss costs)
readonly PERF_EVENTS_B2="dTLB-load-misses,dTLB-store-misses,iTLB-load-misses,cpu-cycles"
# B3 — Backend stalls: whether the CPU is actually waiting on the memory subsystem
readonly PERF_EVENTS_B3="stalled-cycles-backend,stalled-cycles-frontend,cpu-cycles,instructions"

# Internal repetitions per perf stat invocation (perf stat -r N → outputs mean ± stddev).
readonly PERF_STAT_REPEATS=3

# Seconds the benchmark binary runs during the thermal warmup run (results discarded).
readonly PERF_WARMUP_SECONDS="15.0"

# ── System state setup — called once before the benchmark suite ───────────────
#
# Requires passwordless sudo for the relevant sysfs/procfs paths, or run as root.
# Exits on any failure — do not proceed with invalid system state.
setup_system_state() {
    echo "[SETUP] Configuring system for benchmarking…"

    # perf_event_paranoid ≤ 1 required for hardware counters.
    echo "[SETUP]   perf_event_paranoid = 1"
    echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid > /dev/null || {
        echo "[ERROR] Failed: echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid" >&2; exit 1; }

    # NMI watchdog occupies one PMU slot.
    echo "[SETUP]   nmi_watchdog = 0"
    echo 0 | sudo tee /proc/sys/kernel/nmi_watchdog > /dev/null || {
        echo "[ERROR] Failed: echo 0 | sudo tee /proc/sys/kernel/nmi_watchdog" >&2; exit 1; }

    # Performance governor pins CPU at max rated frequency.
    echo "[SETUP]   scaling_governor = performance (all CPUs)"
    # Use a loop — tee with glob expansion can silently skip failures.
    local gov_failed=0
    for gov_path in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ -f "$gov_path" ]] || continue
        echo performance | sudo tee "$gov_path" > /dev/null || gov_failed=1
    done
    if [[ "$gov_failed" -ne 0 ]]; then
        echo "[ERROR] Failed to set governor on one or more CPUs." >&2; exit 1
    fi

    # Disable turbo — Intel path.
    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        echo "[SETUP]   Intel turbo → disabled"
        echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo > /dev/null || {
            echo "[ERROR] Failed: echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo" >&2; exit 1; }
    fi

    # Disable boost — AMD path.
    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        echo "[SETUP]   AMD boost → disabled"
        echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost > /dev/null || {
            echo "[ERROR] Failed: echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost" >&2; exit 1; }
    fi

    echo "[SETUP] Done."
}

# ── Prerequisite checks — all fatal on failure ─────────────────────────────────

check_deps() {
    local missing=()
    for cmd in perf taskset numactl timeout; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[ERROR] Missing required tools: ${missing[*]}" >&2
        echo "[ERROR] Install: linux-tools (perf), util-linux (taskset/chrt), numactl, coreutils (timeout)." >&2
        exit 1
    fi
}

# Hardware counters require paranoid ≤ 1.
check_perf_paranoid() {
    local paranoid
    paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "2")
    if [[ "$paranoid" -gt 1 ]]; then
        echo "[ERROR] perf_event_paranoid=${paranoid} — must be ≤1 for hardware counters." >&2
        echo "[ERROR] Fix: echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid" >&2
        exit 1
    fi
}

# Turbo boost causes mid-benchmark frequency spikes — timing and cycle counts are invalid.
check_turbo_disabled() {
    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        local no_turbo
        no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo "0")
        if [[ "$no_turbo" != "1" ]]; then
            echo "[ERROR] Intel turbo boost is enabled — cycle counts will be non-reproducible." >&2
            echo "[ERROR] Fix: echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo" >&2
            exit 1
        fi
    elif [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        local boost
        boost=$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo "1")
        if [[ "$boost" != "0" ]]; then
            echo "[ERROR] AMD boost is enabled — cycle counts will be non-reproducible." >&2
            echo "[ERROR] Fix: echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost" >&2
            exit 1
        fi
    elif [[ "${BENCH_SKIP_TURBO_CHECK:-0}" != "1" ]]; then
        echo "[ERROR] Cannot determine turbo state (neither Intel nor AMD path found)." >&2
        echo "[ERROR] Set BENCH_SKIP_TURBO_CHECK=1 to override (taints results)." >&2
        exit 1
    fi
}

# NMI watchdog occupies one PMU slot — may force multiplexing with 4-event groups.
check_nmi_watchdog() {
    local nmi
    nmi=$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null || echo "0")
    if [[ "$nmi" != "0" ]]; then
        echo "[ERROR] NMI watchdog is enabled — consumes a PMU counter slot." >&2
        echo "[ERROR] Fix: echo 0 | sudo tee /proc/sys/kernel/nmi_watchdog" >&2
        exit 1
    fi
}

# powersave/schedutil governors allow frequency changes mid-benchmark.
check_scaling_governor() {
    local cpu="$1"
    local gov_path="/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor"
    if [[ ! -f "$gov_path" ]]; then
        echo "[WARN] No cpufreq governor path for CPU${cpu} — skipping governor check." >&2
        return 0
    fi
    local gov
    gov=$(cat "$gov_path" 2>/dev/null || echo "unknown")
    if [[ "$gov" != "performance" ]]; then
        echo "[ERROR] CPU${cpu} scaling_governor='${gov}' — must be 'performance'." >&2
        echo "[ERROR] Fix: echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor" >&2
        exit 1
    fi
}

# ── CPU isolation ──────────────────────────────────────────────────────────────

_get_isolcpus_param() {
    grep -oP '(?<=isolcpus=)\S+' /proc/cmdline 2>/dev/null || true
}

_expand_cpu_range() {
    local token="$1"
    if [[ "$token" == *-* ]]; then
        seq "${token%-*}" "${token#*-}"
    else
        echo "$token"
    fi
}

# Selects the CPU to pin benchmarks to. Priority:
#   1. BENCH_CPU env var (explicit override)
#   2. First CPU from isolcpus= kernel parameter (best isolation)
#   3. Auto-pick: last online non-zero CPU (process-level taskset only — some OS noise)
select_bench_cpu() {
    if [[ -n "${BENCH_CPU:-}" ]]; then
        echo "$BENCH_CPU"
        return
    fi

    local isolcpus
    isolcpus=$(_get_isolcpus_param)
    if [[ -n "$isolcpus" ]]; then
        local first_token
        first_token=$(echo "$isolcpus" | tr ',' '\n' | head -1)
        _expand_cpu_range "$first_token" | head -1
        return
    fi

    # No isolcpus — warn and auto-pick the last online CPU (avoids CPU 0 / IRQ CPU).
    echo "[WARN] isolcpus= not set in kernel cmdline — using taskset pinning only." >&2
    echo "[WARN] For rigorous results: add 'isolcpus=N nohz_full=N rcu_nocbs=N' to GRUB_CMDLINE_LINUX and reboot." >&2
    echo "[WARN] Override with: BENCH_CPU=<N> make run-all" >&2

    local last_cpu
    last_cpu=$(ls /sys/devices/system/cpu/cpu[0-9]*/online 2>/dev/null \
        | sed 's|.*cpu\([0-9]*\)/.*|\1|' \
        | sort -n | tail -1)
    if [[ -z "$last_cpu" ]]; then
        last_cpu=$(( $(nproc --all 2>/dev/null || echo 2) - 1 ))
        [[ "$last_cpu" -lt 1 ]] && last_cpu=1
    fi
    echo "$last_cpu"
}

# HT sibling check — warn-only when isolcpus is absent (best-effort mode).
check_ht_sibling_isolated() {
    local cpu="$1"
    local sibling_path="/sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list"
    [[ -f "$sibling_path" ]] || return 0

    local isolcpus
    isolcpus=$(_get_isolcpus_param)
    [[ -z "$isolcpus" ]] && return 0   # no kernel isolation — skip, already warned

    local isolated_cpus=()
    while IFS= read -r token; do
        while IFS= read -r expanded; do
            isolated_cpus+=("$expanded")
        done < <(_expand_cpu_range "$token")
    done < <(echo "$isolcpus" | tr ',' '\n')

    local siblings
    siblings=$(cat "$sibling_path" 2>/dev/null || echo "")
    local sibling
    for sibling in $(echo "$siblings" | tr ',' '\n'); do
        [[ "$sibling" == "$cpu" ]] && continue
        local found=0
        local c
        for c in "${isolated_cpus[@]}"; do
            [[ "$c" == "$sibling" ]] && { found=1; break; }
        done
        if [[ "$found" -eq 0 ]]; then
            echo "[ERROR] HT sibling CPU${sibling} of CPU${cpu} is NOT isolated." >&2
            echo "[ERROR] The sibling shares L2 cache and PMU hardware — measurements will be contaminated." >&2
            echo "[ERROR] Add CPU${sibling} to isolcpus= in GRUB_CMDLINE_LINUX and reboot." >&2
            exit 1
        fi
    done
}

# ── RT scheduling ──────────────────────────────────────────────────────────────

_rt_prefix() {
    local -n _out=$1
    if command -v chrt &>/dev/null && chrt -f 99 true 2>/dev/null; then
        _out=(chrt -f 99)
    else
        echo "[WARN] chrt -f 99 unavailable — skipping RT scheduling (requires root or CAP_SYS_NICE)." >&2
        _out=()
    fi
}

# ── Consolidated system check + CPU selection ──────────────────────────────────

# Runs all required system checks. Sets the named variable to the isolated CPU number.
# Skips checks when BENCH_SKIP_CHECKS=1 and BENCH_CPU is set (for orchestrator re-use).
_prepare_run() {
    local -n _cpu_out=$1

    if [[ "${BENCH_SKIP_CHECKS:-0}" == "1" ]]; then
        _cpu_out="${BENCH_CPU:?BENCH_CPU must be set when BENCH_SKIP_CHECKS=1}"
        return
    fi

    check_deps
    check_perf_paranoid
    check_nmi_watchdog
    check_turbo_disabled

    _cpu_out=$(select_bench_cpu)
    check_scaling_governor "$_cpu_out"
    check_ht_sibling_isolated "$_cpu_out"

    echo "[INFO] System checks passed." >&2
    echo "[INFO] Isolated CPU: ${_cpu_out}" >&2
    echo "[INFO] NUMA: memory and execution bound to node 0 via numactl --membind=0" >&2
}

# Public wrapper used by run_all.sh for the one-time environment check.
# Runs all checks and prints the selected CPU number to stdout.
prepare_environment_once() {
    local cpu
    _prepare_run cpu
    echo "$cpu"
}

# ── Conditions record ─────────────────────────────────────────────────────────

# Reads live sysfs values and writes a JSON attestation file alongside results.
# Any result file without this record, or with turbo_disabled=false, is invalid.
write_conditions() {
    local result_dir="$1"
    local cpu="$2"
    local ts="$3"
    local out="${result_dir}/conditions_${ts}.json"

    local governor paranoid nmi turbo_disabled isolcpus_active rt_scheduling

    governor=$(cat "/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_governor" 2>/dev/null || echo "unknown")
    paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "-1")
    nmi=$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null || echo "-1")

    turbo_disabled="false"
    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        [[ "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)" == "1" ]] && turbo_disabled="true"
    elif [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        [[ "$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)" == "0" ]] && turbo_disabled="true"
    fi

    isolcpus_active="false"
    [[ -n "$(_get_isolcpus_param)" ]] && isolcpus_active="true"

    rt_scheduling="false"
    command -v chrt &>/dev/null && chrt -f 99 true 2>/dev/null && rt_scheduling="true"

    cat > "$out" <<EOF
{
  "timestamp": "$(date --iso-8601=seconds)",
  "cpu": ${cpu},
  "governor": "${governor}",
  "perf_event_paranoid": ${paranoid},
  "turbo_disabled": ${turbo_disabled},
  "nmi_watchdog_disabled": $([[ "$nmi" == "0" ]] && echo "true" || echo "false"),
  "isolcpus_active": ${isolcpus_active},
  "rt_scheduling": ${rt_scheduling}
}
EOF
    echo "[INFO] conditions → $(basename "$out")"
}

# ── Sample event detection (PEBS :pp → :p → plain) ───────────────────────────

_detect_sample_event() {
    local tmp
    tmp=$(mktemp /tmp/perf_probe_XXXXXX.data)
    for modifier in ":pp" ":p" ""; do
        if perf record -e "LLC-load-misses${modifier}" -o "$tmp" -- true &>/dev/null 2>&1; then
            rm -f "$tmp"
            echo "LLC-load-misses${modifier}"
            return
        fi
    done
    rm -f "$tmp"
    echo "LLC-load-misses"
}

# ── Pass A: in-process PerfCounterGroup ────────────────────────────────────────
# run_bench_counter BINARY RESULT_DIR INVOCATIONS [EXTRA_GBENCH_ARGS...]
#
# Binary must be built WITHOUT -DDISABLE_PERF_COUNTER (MODE=counter).
# Writes RESULT_DIR/gbench_<ts>.json and RESULT_DIR/conditions_<ts>.json per invocation.
run_bench_counter() {
    local binary="$1"
    local result_dir="$2"
    local invocations="${3:-1}"
    shift 3
    mkdir -p "$result_dir"

    local cpu
    _prepare_run cpu

    local rt=()
    _rt_prefix rt

    for i in $(seq 1 "$invocations"); do
        local ts
        ts=$(date +%Y%m%d_%H%M%S_%N)
        local gbench_out="${result_dir}/gbench_${ts}.json"

        echo "[INFO] ── Pass A [${i}/${invocations}]: $(basename "$binary") ──"
        write_conditions "$result_dir" "$cpu" "$ts"

        numactl --membind=0 \
            taskset -c "$cpu" \
            "${rt[@]}" \
            "${binary}" \
                --benchmark_format=json \
                --benchmark_out="${gbench_out}" \
                --benchmark_color=false \
                "$@"

        echo "[INFO] gbench → ${gbench_out}"
        echo ""
    done
    echo "[INFO] Pass A complete → ${result_dir}/"
}

# ── Pass B: split perf stat passes ─────────────────────────────────────────────
# run_bench_perf_all BINARY RESULT_DIR INVOCATIONS [EXTRA_GBENCH_ARGS...]
#
# Binary must be built WITH -DDISABLE_PERF_COUNTER (MODE=perf).
# Runs three sequential passes per invocation:
#   b1_cache/   — L1 and LLC miss rates        (perf_<ts>.csv + gbench_<ts>.json)
#   b2_tlb/     — TLB pressure                 (perf_<ts>.csv + gbench_<ts>.json)
#   b3_stalls/  — backend stall cycles         (perf_<ts>.csv + gbench_<ts>.json)
# A thermal warmup run precedes the first invocation.
run_bench_perf_all() {
    local binary="$1"
    local result_dir="$2"
    local invocations="${3:-1}"
    shift 3
    mkdir -p "${result_dir}/b1_cache" "${result_dir}/b2_tlb" "${result_dir}/b3_stalls"

    local cpu
    _prepare_run cpu

    local rt=()
    _rt_prefix rt

    # Thermal warmup: run the binary for PERF_WARMUP_SECONDS, discard output.
    echo "[INFO] Thermal warmup (${PERF_WARMUP_SECONDS}s) — results discarded"
    numactl --membind=0 \
        taskset -c "$cpu" \
        "${binary}" \
            --benchmark_repetitions=1 \
            --benchmark_min_time="${PERF_WARMUP_SECONDS}" \
            --benchmark_color=false > /dev/null 2>&1 || true
    echo "[INFO] Warmup complete"
    echo ""

    # Shared gbench flags: perf stat controls external repetitions via -r.
    local gbench_args=(
        --benchmark_format=json
        --benchmark_color=false
        --benchmark_repetitions=1
    )

    for i in $(seq 1 "$invocations"); do
        local ts
        ts=$(date +%Y%m%d_%H%M%S_%N)

        echo "[INFO] ── Pass B [${i}/${invocations}]: $(basename "$binary") ──"
        write_conditions "$result_dir" "$cpu" "$ts"

        # B1 — Cache locality
        local b1_perf="${result_dir}/b1_cache/perf_${ts}.csv"
        local b1_gbench="${result_dir}/b1_cache/gbench_${ts}.json"
        echo "[INFO]   B1 cache   → b1_cache/perf_${ts}.csv"
        numactl --membind=0 \
            taskset -c "$cpu" \
            "${rt[@]}" \
            perf stat \
                -e "${PERF_EVENTS_B1}" \
                -r "${PERF_STAT_REPEATS}" \
                --field-separator=, \
                -o "${b1_perf}" \
                -- "${binary}" "${gbench_args[@]}" --benchmark_out="${b1_gbench}" "$@"

        # B2 — TLB pressure
        local b2_perf="${result_dir}/b2_tlb/perf_${ts}.csv"
        local b2_gbench="${result_dir}/b2_tlb/gbench_${ts}.json"
        echo "[INFO]   B2 TLB     → b2_tlb/perf_${ts}.csv"
        numactl --membind=0 \
            taskset -c "$cpu" \
            "${rt[@]}" \
            perf stat \
                -e "${PERF_EVENTS_B2}" \
                -r "${PERF_STAT_REPEATS}" \
                --field-separator=, \
                -o "${b2_perf}" \
                -- "${binary}" "${gbench_args[@]}" --benchmark_out="${b2_gbench}" "$@"

        # B3 — Backend stalls
        local b3_perf="${result_dir}/b3_stalls/perf_${ts}.csv"
        local b3_gbench="${result_dir}/b3_stalls/gbench_${ts}.json"
        echo "[INFO]   B3 stalls  → b3_stalls/perf_${ts}.csv"
        numactl --membind=0 \
            taskset -c "$cpu" \
            "${rt[@]}" \
            perf stat \
                -e "${PERF_EVENTS_B3}" \
                -r "${PERF_STAT_REPEATS}" \
                --field-separator=, \
                -o "${b3_perf}" \
                -- "${binary}" "${gbench_args[@]}" --benchmark_out="${b3_gbench}" "$@"

        echo ""
    done
    echo "[INFO] Pass B complete → ${result_dir}/"
}

# Kept for backwards compatibility.
run_bench_perf_only() { run_bench_perf_all "$@"; }

# ── Pass C: sampling (perf record + annotate + report) ────────────────────────
# run_bench_sampling BINARY RESULT_DIR
#
# Binary must be built WITH -DDISABLE_PERF_COUNTER (MODE=perf) AND with -g (debug symbols).
# One run only — statistical sampling accumulates across many gbench iterations internally.
# Writes:
#   RESULT_DIR/sampling/perf_<ts>.data       — raw sample data
#   RESULT_DIR/sampling/annotate_<ts>.txt    — human-readable source annotation
#   RESULT_DIR/sampling/report_<ts>.csv      — machine-parseable per-symbol overhead
run_bench_sampling() {
    local binary="$1"
    local result_dir="$2"
    mkdir -p "${result_dir}/sampling"

    local cpu
    _prepare_run cpu

    local rt=()
    _rt_prefix rt

    local sample_event
    sample_event=$(_detect_sample_event)
    echo "[INFO] Sampling event: ${sample_event}"

    local ts
    ts=$(date +%Y%m%d_%H%M%S_%N)
    local perf_data="${result_dir}/sampling/perf_${ts}.data"
    local annotate_out="${result_dir}/sampling/annotate_${ts}.txt"
    local report_out="${result_dir}/sampling/report_${ts}.csv"

    write_conditions "${result_dir}/sampling" "$cpu" "$ts"

    echo "[INFO] ── Pass C (sampling): $(basename "$binary") ──"
    echo "[INFO] perf.data → sampling/perf_${ts}.data"

    numactl --membind=0 \
        taskset -c "$cpu" \
        "${rt[@]}" \
        perf record \
            -e "${sample_event}" \
            -o "${perf_data}" \
            -- "${binary}" \
                --benchmark_repetitions=1 \
                --benchmark_color=false > /dev/null 2>&1

    echo "[INFO] Annotating → sampling/annotate_${ts}.txt"
    perf annotate -i "${perf_data}" --stdio > "${annotate_out}" 2>&1 || {
        echo "[WARN] perf annotate failed — rebuild binary with -g for source-level attribution." >&2
    }

    echo "[INFO] Reporting → sampling/report_${ts}.csv"
    perf report \
        -i "${perf_data}" \
        --stdio \
        --field-separator=, \
        -F overhead,sample,symbol,srcfile,srcline \
        > "${report_out}" 2>/dev/null || {
        echo "[WARN] perf report failed — partial or empty report." >&2
    }

    echo "[INFO] Pass C complete → ${result_dir}/sampling/"
}
