#include <iostream>

#if defined(LAYOUT_SOA)
  #include "variants/soa_layout.hpp"
  using ParticleSystemImpl = SoAParticleSystem;
#elif defined(LAYOUT_ALIGNED)
  #include "variants/aligned_layout.hpp"
  using ParticleSystemImpl = AlignedParticleSystem;
#else
  #include "variants/aos_layout.hpp"
  using ParticleSystemImpl = AoSParticleSystem;
#endif

int main(int argc, char *argv[]) {
    ParticleSystemImpl system(0.1);
    system.initialize(100);
    for (int i = 0; i < 1000; ++i) {
        system.step();
    }
}
