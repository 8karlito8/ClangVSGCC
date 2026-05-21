#include "aos_layout.hpp"
#include <random>
#include "../common/SimulationBox.hpp"
#include "../../measurement/benchmark_config.hpp"

void AoSParticleSystem::initialize(int num_particles) {
    particles_.resize(num_particles);
    std::uniform_real_distribution<double> pos_dist(SimulationBox::min, SimulationBox::max);
    std::uniform_real_distribution<double> vel_dist(config::VEL_INIT_MIN, config::VEL_INIT_MAX);
    std::uniform_real_distribution<double> mass_dist(config::MASS_INIT_MIN, config::MASS_INIT_MAX);

    for (auto& particle : particles_) {
        particle.position = Vector(pos_dist(rng_), pos_dist(rng_), pos_dist(rng_));
        particle.velocity = Vector(vel_dist(rng_), vel_dist(rng_), vel_dist(rng_));
        particle.mass = mass_dist(rng_);
        particle.force = Vector(0, 0, 0);
        particle.acceleration = Vector(0, 0, 0);
    }
}

void AoSParticleSystem::compute_forces() {
    // Reset forces
    for (auto& particle : particles_) {
        particle.force = Vector(0, 0, 0);
    }

    // Pairwise force calculation (O(N²))
    for (size_t i = 0; i < particles_.size(); ++i) {
        for (size_t j = i + 1; j < particles_.size(); ++j) {
            auto& p1 = particles_[i];
            auto& p2 = particles_[j];

            Vector r = p2.position - p1.position;
            double r_sq_soft = r.x*r.x + r.y*r.y + r.z*r.z + softening_*softening_;
            double inv_r_soft = 1.0 / std::sqrt(r_sq_soft);
            // Plummer softening: F = G·m₁·m₂·r / (r²+ε²)^(3/2)
            double scale = G * p1.mass * p2.mass * inv_r_soft * inv_r_soft * inv_r_soft;
            Vector force_vec = r * scale;

            // Apply forces (Newton's 3rd law)
            p1.force = p1.force + force_vec;
            p2.force = p2.force - force_vec;
        }
    }
}

void AoSParticleSystem::update_positions() {
    for (auto& particle : particles_) {
        // Update acceleration
        particle.acceleration = particle.force * (1.0 / particle.mass);

        // Update velocity (v = v + a * dt)
        particle.velocity = particle.velocity + particle.acceleration * dt_;

        // Update position (p = p + v * dt)
        particle.position = particle.position + particle.velocity * dt_;

        // Handle box collisions
        SimulationBox::handle_collision(particle.position, particle.velocity);
    }
}

void AoSParticleSystem::step() {
    compute_forces();
    update_positions();
}
