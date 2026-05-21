#include <iostream>
#include <iomanip>
#include "measurement/benchmark_config.hpp"
#include "matrix/validation.hpp"
#include "matrix/variants/matrix_base.hpp"

#if defined(LAYOUT_ROW_MAJOR)
  #include "matrix/variants/row_major.hpp"
  using MatrixSystemImpl = RowMajorSystem;
  static constexpr std::string_view LAYOUT_NAME = "Row-Major";
#else
  #include "matrix/variants/tile_contiguous.hpp"
  using MatrixSystemImpl = TileContiguousSystem;
  static constexpr std::string_view LAYOUT_NAME = "Tile-Contiguous";
#endif

int main() {
    const size_t N = config::MATRIX_N;

    std::cout << "=== Matrix Transpose Correctness Runner ===\n"
              << "Layout     : " << LAYOUT_NAME << "\n"
              << "Matrix size: " << N << " x " << N << "\n"
              << "Config N   : " << config::MATRIX_N << "\n"
              << "Tile size B: " << config::TILE_SIZE_B << "\n\n";

    std::cout << "System initialized, running transpose...\n";

    MatrixSystemImpl system(N);
    system.initialize();
    std::cout << "Initialize complete.\n";

    std::cout << "\nSource matrix (first 5x5):\n";
    const auto& src = system.get_src();
    for (size_t i = 0; i < std::min(5UL, N); ++i) {
        for (size_t j = 0; j < std::min(5UL, N); ++j) {
            std::cout << std::setw(8) << std::setprecision(3) << src.get(i, j) << " ";
        }
        std::cout << "\n";
    }

    std::cout << "\nRunning transpose...\n";
    system.transpose();
    std::cout << "Transpose complete.\n";

    std::cout << "\nDestination matrix (first 5x5):\n";
    const auto& dst = system.get_dst();
    for (size_t i = 0; i < std::min(5UL, N); ++i) {
        for (size_t j = 0; j < std::min(5UL, N); ++j) {
            std::cout << std::setw(8) << std::setprecision(3) << dst.get(i, j) << " ";
        }
        std::cout << "\n";
    }

    assert(dst.get_data() != nullptr && "dst.get_data() returned nullptr");
    std::cout << "\nData pointer check: PASS\n";

    std::cout << "\nRunning tile indexing verification...\n";
    debug_verify_tile_indexing(N);

    std::cout << "\nRunning transpose validation...\n";
    bool result = validate_matrix_transpose(std::vector<float>(dst.get_data(), dst.get_data() + N * N), N);

    if (result) {
        std::cout << "\n✓ PASS: Transpose correct\n";
        return 0;
    } else {
        std::cout << "\n✗ FAIL: Transpose incorrect\n";
        return 1;
    }
}
