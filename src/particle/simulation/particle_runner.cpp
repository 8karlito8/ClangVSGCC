// Standalone correctness runner — no benchmarking framework.
//
// Validates two invariants after every step:
//   1. All particles remain inside SimulationBox (bounds invariant).
//   2. Total mechanical energy does not drift beyond the configured tolerance.
//
// Layout is selected at compile time via -DLAYOUT_SOA / -DLAYOUT_ALIGNED.
// Default (no define) → AoS.

#include <iostream>
#include <iomanip>
#include <cmath>
#include <string_view>
#include <vector>
#include "../../measurement/benchmark_config.hpp"
#include "../common/SimulationBox.hpp"

#if defined(LAYOUT_SOA)
  #include "particle/variants/soa_layout.hpp"
  using ParticleSystemImpl = SoAParticleSystem;
  static constexpr std::string_view LAYOUT_NAME = "SoA";
#elif defined(LAYOUT_ALIGNED)
  #include "particle/variants/aligned_layout.hpp"
  using ParticleSystemImpl = AlignedParticleSystem;
  static constexpr std::string_view LAYOUT_NAME = "Aligned AoS";
#else
  #include "particle/variants/aos_layout.hpp"
  using ParticleSystemImpl = AoSParticleSystem;
  static constexpr std::string_view LAYOUT_NAME = "AoS";
#endif

// ── Validation helpers ────────────────────────────────────────────────────────

// Returns how many particles are outside the SimulationBox.
static int count_out_of_bounds(const std::vector<Particle>& particles) {
    int oob = 0;
    for (const auto& p : particles)
        if (!SimulationBox::contains(p.position))
            ++oob;
    return oob;
}

// ── Entry point ───────────────────────────────────────────────────────────────

int main() {
    const int    N       = config::PARTICLE_SMALL;
    const int    STEPS   = config::RUNNER_STEPS;
    const int    REPORT  = config::RUNNER_REPORT_INTERVAL;
    const double TOL     = config::RUNNER_ENERGY_TOLERANCE;

    std::cout << "=== Particle Simulation Correctness Runner ===\n"
              << "Layout     : " << LAYOUT_NAME << "\n"
              << "Particles  : " << N           << "\n"
              << "Steps      : " << STEPS       << "\n"
              << "dt         : " << config::DT  << "\n"
              << "Softening  : " << config::SOFTENING << "\n\n";

    ParticleSystemImpl system(config::DT, config::SOFTENING);
    system.initialize(N);

    const double E0  = system.calculate_total_energy();
    const int    oob = count_out_of_bounds(system.get_particles());

    std::cout << std::fixed << std::setprecision(6);
    std::cout << "Initial energy : " << E0  << "\n";
    std::cout << "Initial OOB    : " << oob << " / " << N << "\n\n";
    std::cout << std::string(52, '-') << "\n";
    std::cout << std::setw(7)  << "step"
              << std::setw(16) << "energy"
              << std::setw(12) << "drift %"
              << std::setw(8)  << "OOB"   << "\n";
    std::cout << std::string(52, '-') << "\n";

    bool bounds_failed = false;
    bool energy_failed = false;

    for (int step = 1; step <= STEPS; ++step) {
        system.step();

        // Bounds invariant: collision handler must keep all particles in box.
        const int violations = count_out_of_bounds(system.get_particles());
        if (violations > 0) {
            bounds_failed = true;
            std::cout << "  [step " << step << "] BOUNDS VIOLATION: "
                      << violations << " particle(s) outside SimulationBox\n";
        }

        if (step % REPORT == 0) {
            const double E     = system.calculate_total_energy();
            const double drift = (E0 != 0.0)
                                 ? std::abs((E - E0) / E0) * 100.0
                                 : 0.0;

            std::cout << std::setw(7)  << step
                      << std::setw(16) << E
                      << std::setw(11) << drift << "%"
                      << std::setw(8)  << violations << "\n";
        }
    }

    const double E_final    = system.calculate_total_energy();
    const double total_drift = (E0 != 0.0)
                               ? std::abs((E_final - E0) / E0)
                               : 0.0;

    if (total_drift > TOL)
        energy_failed = true;

    std::cout << std::string(52, '-') << "\n\n";
    std::cout << "=== Final Report ===\n";
    std::cout << "Final energy   : " << E_final << "\n";
    std::cout << "Total drift    : " << total_drift * 100.0 << "% "
              << "(tolerance: " << TOL * 100.0 << "%)\n\n";

    std::cout << "Bounds check   : " << (bounds_failed ? "FAIL" : "PASS") << "\n";
    std::cout << "Energy check   : " << (energy_failed ? "FAIL" : "PASS") << "\n";

    const bool all_pass = !bounds_failed && !energy_failed;
    std::cout << "\nOverall        : " << (all_pass ? "PASS" : "FAIL") << "\n";

    return all_pass ? 0 : 1;
}
