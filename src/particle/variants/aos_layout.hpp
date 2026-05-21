#pragma once

#include "../common/particle_system_base.hpp"
#include <random>

class AoSParticleSystem : public ParticleSystem {
public:
    AoSParticleSystem(double dt, double softening = 1e-5)
        : ParticleSystem(dt, softening) {}

    void initialize(int num_particles) override;
    void step() override;
    void compute_forces() override;
    void update_positions() override;
    const std::vector<Particle>& get_particles() const override { return particles_; }

private:
    std::vector<Particle> particles_;
    std::mt19937 rng_;  // Random number generator
};
