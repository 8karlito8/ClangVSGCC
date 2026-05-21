#pragma once

#include "../common/particle_system_base.hpp"
#include <random>

// True Structure-of-Arrays layout: one contiguous array per scalar field.
// Enables auto-vectorisation of the force inner loop via homogeneous loads.
class SoAParticleSystem : public ParticleSystem {
public:
    SoAParticleSystem(double dt, double softening = 1e-5)
        : ParticleSystem(dt, softening) {}

    void initialize(int num_particles) override;
    void step() override;
    void compute_forces() override;
    void update_positions() override;
    const std::vector<Particle>& get_particles() const override;

private:
    size_t n_ = 0;

    std::vector<double> pos_x_, pos_y_, pos_z_;
    std::vector<double> vel_x_, vel_y_, vel_z_;
    std::vector<double> force_x_, force_y_, force_z_;
    std::vector<double> masses_;

    std::mt19937 rng_;
    mutable std::vector<Particle> particle_cache_;
};
