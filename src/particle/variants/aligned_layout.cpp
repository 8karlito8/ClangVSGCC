#include "aligned_layout.hpp"
#include "../common/SimulationBox.hpp"
#include "../../measurement/benchmark_config.hpp"
#include <random>

void AlignedParticleSystem::initialize(int num_particles) {
    aligned_particles_.resize(num_particles);
    particle_view_.resize(num_particles);

    std::uniform_real_distribution<double> pos_dist(SimulationBox::min, SimulationBox::max);
    std::uniform_real_distribution<double> vel_dist(config::VEL_INIT_MIN, config::VEL_INIT_MAX);
    std::uniform_real_distribution<double> mass_dist(config::MASS_INIT_MIN, config::MASS_INIT_MAX);

    for (int i = 0; i < num_particles; ++i) {
        AlignedParticle& p = aligned_particles_[i];
        p.position = Vector(pos_dist(rng_), pos_dist(rng_), pos_dist(rng_));
        p.velocity = Vector(vel_dist(rng_), vel_dist(rng_), vel_dist(rng_));
        p.acceleration = Vector(0, 0, 0);
        p.force = Vector(0, 0, 0);
        p.mass = mass_dist(rng_);
    }

    // Update the view for base class interface
    update_particle_view();
}

void AlignedParticleSystem::update_particle_view() {
    for (size_t i = 0; i < aligned_particles_.size(); ++i) {
        particle_view_[i] = static_cast<Particle>(aligned_particles_[i]);
    }
}

const std::vector<Particle>& AlignedParticleSystem::get_particles() const {
    return particle_view_;
}

void AlignedParticleSystem::step() {
    compute_forces();
    update_positions();
}

void AlignedParticleSystem::compute_forces() {
    const int n = aligned_particles_.size();

    // Reset forces
    for (int i = 0; i < n; ++i) {
        aligned_particles_[i].force = Vector(0, 0, 0);
    }

    // Compute gravitational forces (N-body)
    for (int i = 0; i < n; ++i) {
        for (int j = i + 1; j < n; ++j) {
            AlignedParticle& p1 = aligned_particles_[i];
            AlignedParticle& p2 = aligned_particles_[j];

            Vector r = p2.position - p1.position;
            double r_sq_soft = r.x*r.x + r.y*r.y + r.z*r.z + softening_*softening_;
            double inv_r_soft = 1.0 / std::sqrt(r_sq_soft);
            // Plummer softening: F = G·m₁·m₂·r / (r²+ε²)^(3/2)
            double scale = G * p1.mass * p2.mass * inv_r_soft * inv_r_soft * inv_r_soft;
            Vector force_vec = r * scale;

            p1.force = p1.force + force_vec;
            p2.force = p2.force - force_vec;
        }
    }
}

void AlignedParticleSystem::update_positions() {
    for (AlignedParticle& particle : aligned_particles_) {
        particle.acceleration = particle.force * (1.0 / particle.mass);
        particle.velocity = particle.velocity + particle.acceleration * dt_;
        particle.position = particle.position + particle.velocity * dt_;
        SimulationBox::handle_collision(particle.position, particle.velocity);
    }

    // Update the view for base class interface
    update_particle_view();
}
