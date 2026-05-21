#include "perf_counter.hpp"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <linux/perf_event.h>

// ── Shared attr builder ───────────────────────────────────────────────────────

static perf_event_attr make_attr(PerfCounter::Event event,
                                 bool is_group_leader = false) {
    perf_event_attr attr{};
    attr.size           = sizeof(attr);
    attr.disabled       = is_group_leader ? 1 : 0;
    attr.exclude_kernel = 1;
    attr.exclude_hv     = 1;

    // PERF_FORMAT_GROUP and time fields are only meaningful on the group
    // leader fd — members get read_format=0 (C4 correction).
    if (is_group_leader) {
        attr.read_format = PERF_FORMAT_GROUP
                         | PERF_FORMAT_TOTAL_TIME_ENABLED
                         | PERF_FORMAT_TOTAL_TIME_RUNNING;
    }

    switch (event) {
        case PerfCounter::Event::L1_MISSES:
            attr.type   = PERF_TYPE_HW_CACHE;
            attr.config = (PERF_COUNT_HW_CACHE_L1D)
                        | (PERF_COUNT_HW_CACHE_OP_READ     << 8)
                        | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16);
            break;
        case PerfCounter::Event::LLC_MISSES:
            attr.type   = PERF_TYPE_HARDWARE;
            attr.config = PERF_COUNT_HW_CACHE_MISSES;
            break;
        case PerfCounter::Event::LLC_REFERENCES:
            attr.type   = PERF_TYPE_HARDWARE;
            attr.config = PERF_COUNT_HW_CACHE_REFERENCES;
            break;
        case PerfCounter::Event::INSTRUCTIONS:
            attr.type   = PERF_TYPE_HARDWARE;
            attr.config = PERF_COUNT_HW_INSTRUCTIONS;
            break;
        case PerfCounter::Event::CYCLES:
            attr.type   = PERF_TYPE_HARDWARE;
            attr.config = PERF_COUNT_HW_CPU_CYCLES;
            break;
    }
    return attr;
}

// ── PerfCounter ───────────────────────────────────────────────────────────────

PerfCounter::PerfCounter(Event event) {
    perf_event_attr attr = make_attr(event);
    attr.disabled = 1;  // standalone counter starts disabled
    fd_ = static_cast<int>(
        syscall(SYS_perf_event_open, &attr, 0, -1, -1, 0));
}

PerfCounter::~PerfCounter() {
    if (fd_ >= 0) close(fd_);
}

void PerfCounter::reset() {
    if (fd_ >= 0) ioctl(fd_, PERF_EVENT_IOC_RESET, 0);
}

void PerfCounter::start() {
    if (fd_ >= 0) ioctl(fd_, PERF_EVENT_IOC_ENABLE, 0);
}

void PerfCounter::stop() {
    if (fd_ >= 0) ioctl(fd_, PERF_EVENT_IOC_DISABLE, 0);
}

long long PerfCounter::read() const {
    if (fd_ < 0) return 0;
    long long value = 0;
    ::read(fd_, &value, sizeof(value));
    return value;
}

// ── PerfCounterGroup ──────────────────────────────────────────────────────────

PerfCounterGroup::~PerfCounterGroup() {
    for (auto it = fds_.rbegin(); it != fds_.rend(); ++it)
        if (*it >= 0) ::close(*it);
}

bool PerfCounterGroup::add(PerfCounter::Event event) {
    const bool is_leader = (leader_fd_ < 0);
    perf_event_attr attr = make_attr(event, is_leader);

    int fd = static_cast<int>(
        ::syscall(SYS_perf_event_open, &attr,
                  0,                           // pid: this process
                  -1,                          // cpu: any
                  is_leader ? -1 : leader_fd_, // group_fd
                  0));

    if (fd < 0) {
        for (int f : fds_) if (f >= 0) ::close(f);
        fds_.clear();
        events_.clear();
        leader_fd_ = -1;
        return false;
    }

    if (is_leader) leader_fd_ = fd;
    fds_.push_back(fd);
    events_.push_back(event);
    return true;
}

void PerfCounterGroup::reset() {
    if (leader_fd_ >= 0)
        ::ioctl(leader_fd_, PERF_EVENT_IOC_RESET, PERF_IOC_FLAG_GROUP);
}

void PerfCounterGroup::start() {
    if (leader_fd_ >= 0)
        ::ioctl(leader_fd_, PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP);
}

void PerfCounterGroup::stop() {
    if (leader_fd_ >= 0)
        ::ioctl(leader_fd_, PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP);
}

PerfCounterGroup::Reading PerfCounterGroup::read() const {
    Reading r;
    if (leader_fd_ < 0) return r;

    // Buffer layout for PERF_FORMAT_GROUP|TIME_ENABLED|TIME_RUNNING:
    //   u64 nr
    //   u64 time_enabled
    //   u64 time_running
    //   u64 value[nr]
    const std::size_t expected = fds_.size();
    std::vector<uint64_t> buf(3 + expected, 0);

    if (::read(leader_fd_, buf.data(), buf.size() * sizeof(uint64_t)) < 0)
        return r;

    // C3: validate nr returned by kernel matches our group size.
    const uint64_t nr = buf[0];
    if (nr != static_cast<uint64_t>(expected)) return r;

    r.time_enabled = buf[1];
    r.time_running = buf[2];
    r.values.resize(expected);
    for (std::size_t i = 0; i < expected; ++i)
        r.values[i] = static_cast<long long>(buf[3 + i]);
    return r;
}

int PerfCounterGroup::index_of(PerfCounter::Event event) const {
    auto it = std::find(events_.begin(), events_.end(), event);
    return (it == events_.end())
        ? -1
        : static_cast<int>(std::distance(events_.begin(), it));
}
