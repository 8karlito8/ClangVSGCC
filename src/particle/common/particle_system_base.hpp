#pragma once

#include <vector>
#include <cmath>

// Gravitational constant
constexpr double G = 6.674e-11; // Constant

// 3D vector structure
struct Vector {
    double x, y, z;

    Vector() : x(0), y(0), z(0) {}
    Vector(double x, double y, double z) : x(x), y(y), z(z) {}

    // Vector operations
    Vector operator+(const Vector& other) const {
        return Vector(x + other.x, y + other.y, z + other.z);
    }

    Vector operator-(const Vector& other) const {
        return Vector(x - other.x, y - other.y, z - other.z);
    }

    Vector operator*(double scalar) const {
        return Vector(x * scalar, y * scalar, z * scalar);
    }

    double magnitude() const {
        return std::sqrt(x * x + y * y + z * z);
    }

    Vector normalized() const {
        double mag = magnitude();
        return Vector(x / mag, y / mag, z / mag);
    }
};

// Particle structure
struct Particle {
    Vector position;
    Vector velocity;
    Vector acceleration;
    Vector force;
    double mass;
};

// Base class for particle systems
class ParticleSystem {
public:
    ParticleSystem(double dt, double softening = 1e-5)
        : dt_(dt), softening_(softening) {}

    virtual ~ParticleSystem() = default;

    // Initialize particles with random positions and velocities
    virtual void initialize(int num_particles) = 0;

    // Perform one timestep
    virtual void step() = 0;

    // Compute forces on all particles
    virtual void compute_forces() = 0;

    // Update positions and velocities
    virtual void update_positions() = 0;

    // Get particle data for validation
    virtual const std::vector<Particle>& get_particles() const = 0;

    // Calculate total energy (for validation)
    double calculate_total_energy() const;

    // Calculate kinetic energy
    double calculate_kinetic_energy() const;

    // Calculate potential energy
    double calculate_potential_energy() const;

protected:
    double dt_;  // Timestep size
    double softening_;  // Softening parameter to prevent division by zero
};

inline double ParticleSystem::calculate_kinetic_energy() const {
    double energy = 0.0;
    for (const auto& particle : get_particles()) {
        double speed = particle.velocity.magnitude();
        energy += 0.5 * particle.mass * speed * speed;
    }
    return energy;
}

inline double ParticleSystem::calculate_potential_energy() const {
    double energy = 0.0;
    const auto& particles = get_particles();

    for (size_t i = 0; i < particles.size(); ++i) {
        for (size_t j = i + 1; j < particles.size(); ++j) {
            const auto& p1 = particles[i];
            const auto& p2 = particles[j];

            Vector r = p2.position - p1.position;
            double r_mag = r.magnitude();
            energy -= G * p1.mass * p2.mass / r_mag;
        }
    }

    return energy;
}

inline double ParticleSystem::calculate_total_energy() const {
    return calculate_kinetic_energy() + calculate_potential_energy();
}

