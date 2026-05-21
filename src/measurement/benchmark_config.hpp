#pragma once

// Single point of configuration for all benchmarks.
// Edit values here; every benchmark and runner picks them up.

#include <cstddef>
namespace config {

// ── Workload sizes (passed as benchmark range arguments) ─────────────────────
inline constexpr int PARTICLE_SMALL  =  512;
inline constexpr int PARTICLE_MEDIUM = 2048;
inline constexpr int PARTICLE_LARGE  = 8192;

// ── Physics ───────────────────────────────────────────────────────────────────
inline constexpr double DT         = 0.01;
inline constexpr double SOFTENING  = 1e-5;

// ── Particle initialization ───────────────────────────────────────────────────
inline constexpr double VEL_INIT_MIN  = -0.1;
inline constexpr double VEL_INIT_MAX  =  0.1;
inline constexpr double MASS_INIT_MIN =  0.5;
inline constexpr double MASS_INIT_MAX =  2.0;

// One physics step per Google Benchmark iteration.
// Phase-separated counter windows make multi-step amortization unnecessary.
inline constexpr int STEPS_PER_ITER = 1;

// ── Standalone runner ────────────────────────────────────────────────────────
inline constexpr int    RUNNER_STEPS             = 500;
inline constexpr int    RUNNER_REPORT_INTERVAL   = 100;
inline constexpr double RUNNER_ENERGY_TOLERANCE  = 0.10;

// ── Google Benchmark ─────────────────────────────────────────────────────────
// perf-mode binaries use 1 rep: perf stat -r 3 provides the external repetitions.
// Counter-mode binaries use 25 for statistical robustness.
#ifdef DISABLE_PERF_COUNTER
inline constexpr int    REPETITIONS         = 1;
#else
inline constexpr int    REPETITIONS         = 12;
#endif
inline constexpr double MIN_BENCH_SECONDS   = 1.5;

// ── Matrix workload ──────────────────────────────────────────────────────────
inline constexpr std::size_t MATRIX_N    = 1024;
inline constexpr std::size_t TILE_SIZE_B = 64;

} // namespace config
