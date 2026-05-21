#include "soa_layout.hpp"
#include "../common/SimulationBox.hpp"
#include "../../measurement/benchmark_config.hpp"

#include <algorithm>
#include <cmath>
#include <random>

void SoAParticleSystem::initialize(int num_particles) {
    n_ = static_cast<size_t>(num_particles);

    pos_x_.resize(n_);  pos_y_.resize(n_);  pos_z_.resize(n_);
    vel_x_.resize(n_);  vel_y_.resize(n_);  vel_z_.resize(n_);
    force_x_.assign(n_, 0.0);
    force_y_.assign(n_, 0.0);
    force_z_.assign(n_, 0.0);
    masses_.resize(n_);

    std::uniform_real_distribution<double> pos_dist(SimulationBox::min, SimulationBox::max);
    std::uniform_real_distribution<double> vel_dist(config::VEL_INIT_MIN, config::VEL_INIT_MAX);
    std::uniform_real_distribution<double> mass_dist(config::MASS_INIT_MIN, config::MASS_INIT_MAX);

    for (size_t i = 0; i < n_; ++i) {
        pos_x_[i] = pos_dist(rng_);  pos_y_[i] = pos_dist(rng_);  pos_z_[i] = pos_dist(rng_);
        vel_x_[i] = vel_dist(rng_);  vel_y_[i] = vel_dist(rng_);  vel_z_[i] = vel_dist(rng_);
        masses_[i] = mass_dist(rng_);
    }
}

void SoAParticleSystem::compute_forces() {
    const size_t n    = n_;
    const double eps2 = softening_ * softening_;

    std::fill(force_x_.begin(), force_x_.end(), 0.0);
    std::fill(force_y_.begin(), force_y_.end(), 0.0);
    std::fill(force_z_.begin(), force_z_.end(), 0.0);

    // Raw __restrict__ pointers let the compiler prove no aliasing and
    // emit packed SIMD loads/stores for the inner j loop.
    const double* __restrict__ px = pos_x_.data();
    const double* __restrict__ py = pos_y_.data();
    const double* __restrict__ pz = pos_z_.data();
    const double* __restrict__ m  = masses_.data();
    double* __restrict__ fx = force_x_.data();
    double* __restrict__ fy = force_y_.data();
    double* __restrict__ fz = force_z_.data();

    for (size_t i = 0; i < n; ++i) {
        const double ix = px[i], iy = py[i], iz = pz[i];
        const double mi = m[i];
        double fix = 0.0, fiy = 0.0, fiz = 0.0;

        for (size_t j = i + 1; j < n; ++j) {
            const double dx = px[j] - ix;
            const double dy = py[j] - iy;
            const double dz = pz[j] - iz;

            const double r_sq_soft = dx*dx + dy*dy + dz*dz + eps2;
            const double inv_r     = 1.0 / std::sqrt(r_sq_soft);
            // Plummer softening: F = G·m₁·m₂·r̂ / (r²+ε²), direction r/(r²+ε²)^½
            // Full vector: F_vec = G·m₁·m₂·r / (r²+ε²)^(3/2)
            const double scale = G * mi * m[j] * inv_r * inv_r * inv_r;

            const double dfx = dx * scale;
            const double dfy = dy * scale;
            const double dfz = dz * scale;

            fix += dfx;  fiy += dfy;  fiz += dfz;
            fx[j] -= dfx;
            fy[j] -= dfy;
            fz[j] -= dfz;
        }

        fx[i] += fix;
        fy[i] += fiy;
        fz[i] += fiz;
    }
}

void SoAParticleSystem::update_positions() {
    constexpr double box_min = SimulationBox::min;
    constexpr double box_max = SimulationBox::max;
    constexpr double elast   = SimulationBox::elasticity;

    for (size_t i = 0; i < n_; ++i) {
        const double inv_m = 1.0 / masses_[i];

        vel_x_[i] += force_x_[i] * inv_m * dt_;
        vel_y_[i] += force_y_[i] * inv_m * dt_;
        vel_z_[i] += force_z_[i] * inv_m * dt_;

        pos_x_[i] += vel_x_[i] * dt_;
        pos_y_[i] += vel_y_[i] * dt_;
        pos_z_[i] += vel_z_[i] * dt_;

        // Inline SimulationBox::handle_collision — avoids constructing
        // temporary Vectors and keeps the update loop scalar-friendly.
        if      (pos_x_[i] < box_min) { pos_x_[i] = box_min; vel_x_[i] = -vel_x_[i] * elast; }
        else if (pos_x_[i] > box_max) { pos_x_[i] = box_max; vel_x_[i] = -vel_x_[i] * elast; }
        if      (pos_y_[i] < box_min) { pos_y_[i] = box_min; vel_y_[i] = -vel_y_[i] * elast; }
        else if (pos_y_[i] > box_max) { pos_y_[i] = box_max; vel_y_[i] = -vel_y_[i] * elast; }
        if      (pos_z_[i] < box_min) { pos_z_[i] = box_min; vel_z_[i] = -vel_z_[i] * elast; }
        else if (pos_z_[i] > box_max) { pos_z_[i] = box_max; vel_z_[i] = -vel_z_[i] * elast; }
    }
}

void SoAParticleSystem::step() {
    compute_forces();
    update_positions();
}

const std::vector<Particle>& SoAParticleSystem::get_particles() const {
    particle_cache_.resize(n_);
    for (size_t i = 0; i < n_; ++i) {
        const double inv_m = 1.0 / masses_[i];
        particle_cache_[i].position     = Vector(pos_x_[i], pos_y_[i], pos_z_[i]);
        particle_cache_[i].velocity     = Vector(vel_x_[i], vel_y_[i], vel_z_[i]);
        particle_cache_[i].force        = Vector(force_x_[i], force_y_[i], force_z_[i]);
        particle_cache_[i].acceleration = Vector(force_x_[i] * inv_m,
                                                  force_y_[i] * inv_m,
                                                  force_z_[i] * inv_m);
        particle_cache_[i].mass         = masses_[i];
    }
    return particle_cache_;
}
