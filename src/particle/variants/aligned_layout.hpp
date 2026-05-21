#pragma once

#include "../common/particle_system_base.hpp"
#include <random>

// Each AlignedParticle is 104 bytes of fields; alignas(64) causes the compiler
// to round sizeof up to 128 (the next multiple of 64).  Two cache lines per
// particle is intentional: it keeps every field access cache-line-aligned and
// avoids false-sharing between particles.
struct alignas(64) AlignedParticle {
    Vector position;     // 24 bytes
    Vector velocity;     // 24 bytes
    Vector acceleration; // 24 bytes
    Vector force;        // 24 bytes
    double mass;         //  8 bytes
    // Total: 104 bytes of data; compiler pads to 128 due to alignas(64).

    AlignedParticle() : position(), velocity(), acceleration(), force(), mass(0.0) {}

    AlignedParticle(const Particle& p)
        : position(p.position), velocity(p.velocity),
          acceleration(p.acceleration), force(p.force), mass(p.mass) {}

    operator Particle() const {
        return {position, velocity, acceleration, force, mass};
    }
};

static_assert(sizeof(AlignedParticle)  == 128, "AlignedParticle must be exactly 128 bytes (2 cache lines)");
static_assert(alignof(AlignedParticle) ==  64, "AlignedParticle must be 64-byte (cache-line) aligned");

class AlignedParticleSystem : public ParticleSystem {
public:
    AlignedParticleSystem(double dt, double softening = 1e-5)
        : ParticleSystem(dt, softening) {}

    void initialize(int num_particles) override;
    void step() override;
    void compute_forces() override;
    void update_positions() override;
    const std::vector<Particle>& get_particles() const override;

private:
    std::vector<AlignedParticle> aligned_particles_;
    std::vector<Particle> particle_view_;  // View for base class interface
    std::mt19937 rng_;  // Random number generator

    void update_particle_view();
};
