#include <benchmark/benchmark.h>

#include "measurement/benchmark_config.hpp"
#ifndef DISABLE_PERF_COUNTER
#  include "measurement/perf_counter.hpp"
#endif

#if defined(LAYOUT_ROW_MAJOR)
  #include "matrix/variants/row_major.hpp"
  using MatrixSystemImpl = RowMajorSystem;
#else
  #include "matrix/variants/tile_contiguous.hpp"
  using MatrixSystemImpl = TileContiguousSystem;
#endif

static void BM_MatrixTranspose(benchmark::State& state) {
    MatrixSystemImpl system(config::MATRIX_N);
    system.initialize();

#ifndef DISABLE_PERF_COUNTER
    PerfCounterGroup g;
    const bool perf_ok =
        g.add(PerfCounter::Event::INSTRUCTIONS) &&
        g.add(PerfCounter::Event::CYCLES)        &&
        g.add(PerfCounter::Event::L1_MISSES)     &&
        g.add(PerfCounter::Event::LLC_MISSES)    &&
        g.add(PerfCounter::Event::LLC_REFERENCES);

    long long acc_insn = 0, acc_cyc = 0, acc_l1 = 0, acc_llc = 0, acc_llc_ref = 0;
    bool multiplexed = false;
#endif

    for (auto _ : state) {
#ifndef DISABLE_PERF_COUNTER
        g.reset(); g.start();
#endif
        system.transpose();
#ifndef DISABLE_PERF_COUNTER
        g.stop();
        auto r = g.read();
        if (!r.values.empty()) {
            acc_insn    += value_for(r, g, PerfCounter::Event::INSTRUCTIONS);
            acc_cyc     += value_for(r, g, PerfCounter::Event::CYCLES);
            acc_l1      += value_for(r, g, PerfCounter::Event::L1_MISSES);
            acc_llc     += value_for(r, g, PerfCounter::Event::LLC_MISSES);
            acc_llc_ref += value_for(r, g, PerfCounter::Event::LLC_REFERENCES);
            if (r.multiplexed()) multiplexed = true;
        }
#endif
    }

    state.SetItemsProcessed(
        state.iterations() * static_cast<long long>(config::MATRIX_N * config::MATRIX_N));

#ifndef DISABLE_PERF_COUNTER
    using C = benchmark::Counter;
    if (perf_ok) {
        state.counters["l1_misses"]      = C(static_cast<double>(acc_l1),      C::kAvgIterations);
        state.counters["llc_misses"]     = C(static_cast<double>(acc_llc),     C::kAvgIterations);
        state.counters["llc_references"] = C(static_cast<double>(acc_llc_ref), C::kAvgIterations);
        state.counters["instructions"]   = C(static_cast<double>(acc_insn),    C::kAvgIterations);
        if (acc_cyc > 0) {
            state.counters["ipc"]          = C(static_cast<double>(acc_insn) / static_cast<double>(acc_cyc),
                                               C::kDefaults);
            state.counters["llc_hit_rate"] = C(
                acc_llc_ref > 0
                    ? 1.0 - static_cast<double>(acc_llc) / static_cast<double>(acc_llc_ref)
                    : 0.0,
                C::kDefaults);
        }
        state.counters["multiplexed"] = C(multiplexed ? 1.0 : 0.0, C::kAvgIterations);
    }
#endif
}

BENCHMARK(BM_MatrixTranspose)
    ->Repetitions(static_cast<int>(config::REPETITIONS))
    ->MinTime(config::MIN_BENCH_SECONDS)
    ->ReportAggregatesOnly(false)
    ->Unit(benchmark::kMicrosecond);

BENCHMARK_MAIN();
