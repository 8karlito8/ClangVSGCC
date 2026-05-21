#include <benchmark/benchmark.h>

#include "measurement/benchmark_config.hpp"
#ifndef DISABLE_PERF_COUNTER
#  include "measurement/perf_counter.hpp"
#endif

#if defined(LAYOUT_SOA)
  #include "particle/variants/soa_layout.hpp"
  using ParticleSystemImpl = SoAParticleSystem;
#elif defined(LAYOUT_ALIGNED)
  #include "particle/variants/aligned_layout.hpp"
  using ParticleSystemImpl = AlignedParticleSystem;
#else
  #include "particle/variants/aos_layout.hpp"
  using ParticleSystemImpl = AoSParticleSystem;
#endif

static void BM_ParticleSimulation(benchmark::State& state) {
    const int n = static_cast<int>(state.range(0));

    ParticleSystemImpl system(config::DT, config::SOFTENING);
    system.initialize(n);

#ifndef DISABLE_PERF_COUNTER
    // Single group — 5 FDs, fits within AMD Zen 3's 6 GP slots and Intel's 4 GP + 3 fixed.
    // Reused between phases via reset() to avoid simultaneously-alive fd pairs (10 FDs)
    // that forced multiplexing on the previous two-group design.
    PerfCounterGroup g;
    const bool perf_ok =
        g.add(PerfCounter::Event::INSTRUCTIONS) &&
        g.add(PerfCounter::Event::CYCLES)        &&
        g.add(PerfCounter::Event::L1_MISSES)     &&
        g.add(PerfCounter::Event::LLC_MISSES)    &&
        g.add(PerfCounter::Event::LLC_REFERENCES);

    struct Acc { long long insn=0, cyc=0, l1=0, llc=0, llc_ref=0; };
    Acc af, au;
    bool multiplexed = false;
#endif

    for (auto _ : state) {
#ifndef DISABLE_PERF_COUNTER
        g.reset(); g.start();
#endif
        system.compute_forces();
#ifndef DISABLE_PERF_COUNTER
        g.stop();
        auto rf = g.read();

        g.reset(); g.start();
#endif
        system.update_positions();
#ifndef DISABLE_PERF_COUNTER
        g.stop();
        auto ru = g.read();

        if (!rf.values.empty()) {
            af.insn    += value_for(rf, g, PerfCounter::Event::INSTRUCTIONS);
            af.cyc     += value_for(rf, g, PerfCounter::Event::CYCLES);
            af.l1      += value_for(rf, g, PerfCounter::Event::L1_MISSES);
            af.llc     += value_for(rf, g, PerfCounter::Event::LLC_MISSES);
            af.llc_ref += value_for(rf, g, PerfCounter::Event::LLC_REFERENCES);
            if (rf.multiplexed()) multiplexed = true;
        }
        if (!ru.values.empty()) {
            au.insn    += value_for(ru, g, PerfCounter::Event::INSTRUCTIONS);
            au.cyc     += value_for(ru, g, PerfCounter::Event::CYCLES);
            au.l1      += value_for(ru, g, PerfCounter::Event::L1_MISSES);
            au.llc     += value_for(ru, g, PerfCounter::Event::LLC_MISSES);
            au.llc_ref += value_for(ru, g, PerfCounter::Event::LLC_REFERENCES);
            if (ru.multiplexed()) multiplexed = true;
        }
#endif
    }

    state.SetItemsProcessed(state.iterations() * n);

#ifndef DISABLE_PERF_COUNTER
    using C = benchmark::Counter;
    if (perf_ok) {
        state.counters["l1_misses_forces"]     = C(static_cast<double>(af.l1),      C::kAvgIterations);
        state.counters["llc_misses_forces"]    = C(static_cast<double>(af.llc),     C::kAvgIterations);
        state.counters["llc_references_forces"]= C(static_cast<double>(af.llc_ref), C::kAvgIterations);
        state.counters["instructions_forces"]  = C(static_cast<double>(af.insn),    C::kAvgIterations);
        if (af.cyc > 0) {
            state.counters["ipc_forces"]       = C(static_cast<double>(af.insn) / static_cast<double>(af.cyc),
                                                   C::kDefaults);
            state.counters["llc_hit_rate_forces"] = C(
                af.llc_ref > 0
                    ? 1.0 - static_cast<double>(af.llc) / static_cast<double>(af.llc_ref)
                    : 0.0,
                C::kDefaults);
        }

        state.counters["l1_misses_update"]     = C(static_cast<double>(au.l1),      C::kAvgIterations);
        state.counters["llc_misses_update"]    = C(static_cast<double>(au.llc),     C::kAvgIterations);
        state.counters["llc_references_update"]= C(static_cast<double>(au.llc_ref), C::kAvgIterations);
        state.counters["instructions_update"]  = C(static_cast<double>(au.insn),    C::kAvgIterations);
        if (au.cyc > 0) {
            state.counters["ipc_update"]       = C(static_cast<double>(au.insn) / static_cast<double>(au.cyc),
                                                   C::kDefaults);
            state.counters["llc_hit_rate_update"] = C(
                au.llc_ref > 0
                    ? 1.0 - static_cast<double>(au.llc) / static_cast<double>(au.llc_ref)
                    : 0.0,
                C::kDefaults);
        }

        state.counters["multiplexed"] = C(multiplexed ? 1.0 : 0.0, C::kAvgIterations);
    }
#endif
}

BENCHMARK(BM_ParticleSimulation)
    ->Arg(config::PARTICLE_SMALL)
    ->Arg(config::PARTICLE_MEDIUM)
    ->Arg(config::PARTICLE_LARGE)
    ->Repetitions(config::REPETITIONS)
    ->MinTime(config::MIN_BENCH_SECONDS)
    ->ReportAggregatesOnly(false)
    ->Unit(benchmark::kMillisecond);

BENCHMARK_MAIN();
