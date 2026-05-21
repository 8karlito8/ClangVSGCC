#pragma once

#include <cstdint>
#include <vector>

// ── PerfCounter ───────────────────────────────────────────────────────────────
// RAII wrapper around a single Linux perf_event counter.
//
// If perf_event_open fails (e.g. perf_event_paranoid > 1, missing CAP_PERFMON),
// the counter silently becomes unavailable; check is_available() before use.

class PerfCounter {
public:
    enum class Event {
        L1_MISSES,         // L1 data cache read misses
        LLC_MISSES,        // Last-level cache load misses
        LLC_REFERENCES,    // Last-level cache load references
        INSTRUCTIONS,      // Retired instructions
        CYCLES,            // CPU cycles
    };

    explicit PerfCounter(Event event);
    ~PerfCounter();

    PerfCounter(const PerfCounter&)            = delete;
    PerfCounter& operator=(const PerfCounter&) = delete;

    void reset();
    void start();
    void stop();
    long long read() const;
    bool is_available() const { return fd_ >= 0; }

private:
    int fd_ = -1;
};

// ── PerfCounterGroup ──────────────────────────────────────────────────────────
// Atomic group of perf_event counters.
//
// The kernel schedules all members together — either all count or none do.
// This eliminates independent multiplexing, which would otherwise corrupt
// ratios such as IPC (instructions/cycles).
//
// Usage:
//   PerfCounterGroup g;
//   g.add(PerfCounter::Event::INSTRUCTIONS);  // must be first (becomes leader)
//   g.add(PerfCounter::Event::CYCLES);
//   g.add(PerfCounter::Event::L1_MISSES);
//   g.add(PerfCounter::Event::LLC_MISSES);
//   g.add(PerfCounter::Event::LLC_REFERENCES);
//
//   g.reset(); g.start();
//   // ... work ...
//   g.stop();
//   auto r = g.read();
//   if (r.multiplexed()) { /* warn: counts are estimates */ }
//   long long insn = value_for(r, g, PerfCounter::Event::INSTRUCTIONS);

class PerfCounterGroup {
public:
    struct Reading {
        std::vector<long long> values;       // in add() order
        uint64_t time_enabled = 0;           // ns the group was schedulable
        uint64_t time_running = 0;           // ns the group actually counted

        // True if the PMU shared slots with another fd set.
        // Counts are still valid relative to each other, but represent only
        // a fraction of wall time and should be flagged in output.
        bool multiplexed() const { return time_enabled != time_running; }

        double scale() const {
            return (time_running > 0)
                ? static_cast<double>(time_enabled) / static_cast<double>(time_running)
                : 0.0;
        }
    };

    PerfCounterGroup() = default;
    ~PerfCounterGroup();

    PerfCounterGroup(const PerfCounterGroup&)            = delete;
    PerfCounterGroup& operator=(const PerfCounterGroup&) = delete;

    // Adds an event. First call opens the group leader; subsequent calls
    // attach members. Returns false if perf_event_open fails — the whole
    // group becomes unavailable and all previously opened fds are closed.
    bool add(PerfCounter::Event event);

    void reset();  // PERF_EVENT_IOC_RESET  on leader with PERF_IOC_FLAG_GROUP
    void start();  // PERF_EVENT_IOC_ENABLE on leader with PERF_IOC_FLAG_GROUP
    void stop();   // PERF_EVENT_IOC_DISABLE on leader with PERF_IOC_FLAG_GROUP

    // Single read(2) syscall on the leader returns all counters.
    Reading read() const;

    // Returns the index of an event in the order it was add()-ed, or -1.
    int index_of(PerfCounter::Event event) const;

    bool is_available() const { return leader_fd_ >= 0; }

private:
    int                           leader_fd_ = -1;
    std::vector<int>              fds_;
    std::vector<PerfCounter::Event> events_;
};

// Free helper: extract a single counter value from a Reading by event name.
inline long long value_for(const PerfCounterGroup::Reading& r,
                           const PerfCounterGroup& g,
                           PerfCounter::Event ev) {
    int i = g.index_of(ev);
    if (i < 0 || static_cast<std::size_t>(i) >= r.values.size()) return 0LL;
    return r.values[static_cast<std::size_t>(i)];
}
