# Cache Layout Performance Benchmark: GCC vs Clang

## Project Overview

This project benchmarks data layout transformations (Array-of-Structs vs Struct-of-Arrays) across GCC and Clang at multiple optimization levels (-O2, -O3, -O3_native). It measures cache behavior, IPC, and execution time for two workloads:

1. **Particle N-body simulation** — three variants: AoS, SoA (true), aligned AoS
2. **Matrix transpose** — two variants: row-major, tile-contiguous

The goal: quantify how layout, compiler code-generation, and optimization level interact.

---

## System Setup

### Prerequisites

- Linux with `perf`, CPU governors, and isolcpus support
- GCC 16+, Clang 22+
- Meson, CMake
- Python 3.9+ with pandas and matplotlib
- AMD Ryzen 5800X (results vary by CPU model and state)

### Machine Configuration (Critical for Reproducible Results)

Before benchmarking, isolate CPUs and disable frequency scaling:

#### 1. Isolate CPUs (Boot-time, One-time)

Edit `/etc/default/grub`:
```bash
GRUB_CMDLINE_LINUX_DEFAULT="... isolcpus=15,7 nohz_full=15,7 rcu_nocbs=15,7"
```

**Why CPUs 7 and 15?** Ryzen 5800X has two 4-core CCX (Core Complex) units. CPUs 7 and 15 are paired on the same L3 cache and share memory fabric. Isolating both prevents cross-core interference and ensures the benchmark core (CPU 15) has exclusive L3 cache access. For other CPUs, check your core topology: `lscpu` or `hwloc-lstopo`.

Update and reboot:
```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg && sudo reboot
```

Verify:
```bash
cat /sys/devices/system/cpu/isolated  # Should output: 7,15
```

Don't forget to revert change later

#### 2. Disable Frequency Scaling (Before Each Run)

```bash
sudo bash << 'EOF'
# Disable turbo boost
echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || \
echo 0 > /sys/devices/system/cpu/amd_pstate/boost 2>/dev/null

# Set all cores to performance governor
for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
  echo performance > "$cpu/scaling_governor"
done
EOF
```

#### 3. Verify Machine State

```bash
# Isolated CPUs idle
ps -ef | grep -E "15|7"

# Governor is performance
cat /sys/devices/system/cpu/cpu15/cpufreq/scaling_governor

# Turbo is off
cat /sys/devices/system/cpu/amd_pstate/boost 2>/dev/null || echo "Intel pstate"
```

---

## Building

### Full Build (Recommended)

```bash
make system-setup       # Configure system (turbo, governor)
make build-all          # Compile all variants for GCC and Clang at O2/O3/O3_native
```

### Individual Build

For a specific configuration:
```bash
CC=gcc CXX=g++ meson setup build/gcc/particle/soa/O3 \
  -Dworkload=particle -Dvariant=soa \
  -Dcpp_args="-O3" -Dcpp_link_args="-O3"

meson compile -C build/gcc/particle/soa/O3
```

For more specific builds check makefile.

---

## Running Benchmarks

### Full Pipeline (~2–3 hours)

```bash
make clean-results           # Remove old data
make validate-particle       # Quick sanity check (O2 only)
make validate-matrix         # Quick sanity check (O2 only)
make run-all                 # Full benchmark: 3 phases × all cells
```

### What Runs

- **Phase 1 (counter):** Google Benchmark with in-process perf counters → `results/.../counter/gbench_*.json`
- **Phase 2 (perf):** `perf stat` for L1/LLC/TLB/stalls → `results/.../perf/{b1_cache,b2_tlb,b3_stalls}/`
- **Phase 3 (sampling):** `perf record` for instruction profiles → `results/.../sampling/`
- **Aggregation:** Combine into `results/master.csv`
- **Plotting:** Generate 111 figures → `results/figures/`

### Configuration (in `src/measurement/benchmark_config.hpp`)

```cpp
constexpr size_t REPETITIONS = 12;        // 12 reps per cell
constexpr double MIN_BENCH_SECONDS = 1.5; // 1.5s minimum per rep
constexpr size_t INVOCATIONS = 3;         // 3 independent runs (run_all.sh)
```

Changing these: edit file, then `make build-all && make run-all`.

### Re-analyze Without Re-running

```bash
make reanalyze           # Re-aggregate + re-plot from existing results
```

### Run Single Workload

Edit `run_all.sh` to comment out particle or matrix, then:
```bash
./run_all.sh
```

---

## Results

### Location

```
results/
├── master.csv                    # Aggregated: all counters, all cells
└── figures/
    ├── layout_bars/             # Bar charts per counter
    ├── scaling_lines/           # Timing vs N (particle)
    ├── effect_forest/           # Bootstrap CI comparisons
    ├── timing_overview/         # Wall-clock overview
    ├── compiler_delta/          # GCC vs Clang
    └── merged/                  # Thesis-ready: 1 PNG per (workload, counter)
```

### Key Metrics

- **cpu_time:** Milliseconds (particle) or microseconds (matrix)
- **instructions, ipc:** Per-iteration instruction count and throughput
- **llc_misses, llc_hit_rate:** Last-level cache efficiency
- **l1_misses:** L1 data cache pressure
- **dTLB-store-misses:** TLB pressure on writes

### Important Notes

1. **IPC values are reconstructed** from wall-clock time (`cpu_time × 3.8 GHz`) and instruction counts. ~1–5% systematic error depending on actual CPU frequency.

2. **Results are CPU-specific.** Ryzen 5800X has:
   - 32 KB L1d, 512 KB L2, 32 MB L3
   - Different cache line size and prefetcher behavior than Intel/ARM
   - GCC auto-vectorizes `1.0 / sqrt(x)` at -O3; Clang does not (compiler policy, not layout)

3. **Machine state affects reproducibility:**
   - Thermal throttling reduces clock speed
   - Background tasks on isolated CPUs add noise
   - NUMA placement matters on multi-socket systems

---

## Troubleshooting

**Meson: "Subproject google-benchmark not found"**
```bash
mkdir -p subprojects
meson setup build --wipe
```

**Very High variance (CV > 10%)**
- Verify turbo is off and governor is `performance`
- Check isolated CPUs are idle: `top -p 1` pinned to CPU 15
- Disable background services: `systemctl status | grep running`

**IPC values unrealistic**
- DRAM-saturated (large N): IPC < 0.5 is normal
- Compute-bound (small N, cache-resident): IPC 2–5 is normal
- Compare to wall-clock: 2.3 ms at 4.5 GHz = 10M cycles; 5M instructions = 0.5 IPC is plausible
