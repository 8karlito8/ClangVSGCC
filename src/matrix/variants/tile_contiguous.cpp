#include "tile_contiguous.hpp"
#include <random>
#include <cassert>
#include <iostream>

TileContiguousMatrix::TileContiguousMatrix(size_t N) : Matrix(N) {
    constexpr size_t B = 64;
    constexpr size_t B_bits = 6;
    tile_row_count_ = N >> B_bits;
    tile_col_count_ = N >> B_bits;

    assert((N & 63) == 0 && "N must be divisible by 64");
    assert(tile_row_count_ > 0 && "tile_row_count must be > 0");

    data_.resize(N * N);
    std::cout << "[TileContiguous] Tile layout: " << tile_row_count_ << "x"
              << tile_col_count_ << " tiles of " << B << "x" << B << "\n";
}

inline size_t TileContiguousMatrix::tile_index(size_t i, size_t j) const {
    constexpr size_t B      = 64;
    constexpr size_t B_bits = 6;
    constexpr size_t B_mask = 63;

    size_t tile_row  = i >> B_bits;
    size_t tile_col  = j >> B_bits;
    size_t local_row = i & B_mask;
    size_t local_col = j & B_mask;

    assert(tile_row < tile_row_count_ && tile_col < tile_col_count_ &&
           "Tile indices out of bounds");
    assert(local_row < B && local_col < B && "Local indices out of bounds");

    size_t idx = (tile_row * tile_row_count_ + tile_col) * (B * B)
               + local_row * B + local_col;

    assert(idx < N * N && "Linear index out of bounds");
    return idx;
}

float* TileContiguousMatrix::get_data() const {
    return const_cast<float*>(data_.data());
}

float TileContiguousMatrix::get(size_t i, size_t j) const {
    assert(i < N && j < N && "Index out of bounds");
    return data_[tile_index(i, j)];
}

void TileContiguousMatrix::set(size_t i, size_t j, float val) {
    assert(i < N && j < N && "Index out of bounds");
    data_[tile_index(i, j)] = val;
}

TileContiguousSystem::TileContiguousSystem(size_t N) : MatrixSystem(N), src_(N), dst_(N) {}

void TileContiguousSystem::initialize() {
    std::mt19937 rng(42);
    std::uniform_real_distribution<float> dist(-50.0f, 50.0f);

    for (size_t i = 0; i < src_.N; ++i) {
        for (size_t j = 0; j < src_.N; ++j) {
            src_.set(i, j, dist(rng));
        }
    }

    for (size_t i = 0; i < dst_.N; ++i) {
        for (size_t j = 0; j < dst_.N; ++j) {
            dst_.set(i, j, 0.0f);
        }
    }

    std::cout << "[TileContiguous] Initialized " << src_.N << "x" << src_.N << " matrix\n";
}

void TileContiguousSystem::transpose() {
    for (size_t i = 0; i < src_.N; ++i) {
        for (size_t j = 0; j < src_.N; ++j) {
            dst_.set(j, i, src_.get(i, j));
        }
    }
}

TileContiguousMatrix& TileContiguousSystem::get_src() { return src_; }
TileContiguousMatrix& TileContiguousSystem::get_dst() { return dst_; }
