#ifndef MATRIX_BASE_HPP
#define MATRIX_BASE_HPP

#include <cstddef>

struct Matrix {
    size_t N;
    float* data;

    Matrix(size_t N) : N(N), data(nullptr) {}
    virtual ~Matrix() = default;
    virtual float* get_data() const = 0;
    virtual float get(size_t i, size_t j) const = 0;
    virtual void set(size_t i, size_t j, float val) = 0;
};

class MatrixSystem {
public:
    MatrixSystem(size_t N) {}
    virtual ~MatrixSystem() = default;
    virtual void initialize() = 0;
    virtual void transpose() = 0;
    virtual Matrix& get_src() = 0;
    virtual Matrix& get_dst() = 0;
};

#endif
