#include "row_major.hpp"
#include <random>
#include <cassert>
#include <iostream>

RowMajorMatrix::RowMajorMatrix(size_t N) : Matrix(N) {
    data_.resize(N * N);
}

float* RowMajorMatrix::get_data() const {
    return const_cast<float*>(data_.data());
}

float RowMajorMatrix::get(size_t i, size_t j) const {
    assert(i < N && j < N && "Index out of bounds");
    return data_[i * N + j];
}

void RowMajorMatrix::set(size_t i, size_t j, float val) {
    assert(i < N && j < N && "Index out of bounds");
    data_[i * N + j] = val;
}

RowMajorSystem::RowMajorSystem(size_t N) : MatrixSystem(N), src_(N), dst_(N) {}

void RowMajorSystem::initialize() {
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

    std::cout << "[RowMajor] Initialized " << src_.N << "x" << src_.N << " matrix\n";
}

void RowMajorSystem::transpose() {
    for (size_t i = 0; i < src_.N; ++i) {
        for (size_t j = 0; j < src_.N; ++j) {
            dst_.set(j, i, src_.get(i, j));
        }
    }
}

RowMajorMatrix& RowMajorSystem::get_src() { return src_; }
RowMajorMatrix& RowMajorSystem::get_dst() { return dst_; }
