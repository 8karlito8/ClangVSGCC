#include "particle_system_base.hpp"

struct SimulationBox {
   static constexpr double min        = -50.0;
   static constexpr double max        =  50.0;
   static constexpr double elasticity =   0.8;

   static bool contains(const Vector& pos) {
      return
         pos.x >= min && pos.x <= max &&
         pos.y >= min && pos.y <= max &&
         pos.z >= min && pos.z <= max;
   }

   static void handle_collision(Vector& pos, Vector& vel) {
      if      (pos.x < min) { pos.x = min; vel.x = -vel.x * elasticity; }
      else if (pos.x > max) { pos.x = max; vel.x = -vel.x * elasticity; }

      if      (pos.y < min) { pos.y = min; vel.y = -vel.y * elasticity; }
      else if (pos.y > max) { pos.y = max; vel.y = -vel.y * elasticity; }

      if      (pos.z < min) { pos.z = min; vel.z = -vel.z * elasticity; }
      else if (pos.z > max) { pos.z = max; vel.z = -vel.z * elasticity; }
   }
};
