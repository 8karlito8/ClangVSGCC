#ifndef ROW_MAJOR_HPP
#define ROW_MAJOR_HPP

#include "matrix_base.hpp"
#include <vector>

class RowMajorMatrix : public Matrix {
private:
    std::vector<float> data_;
public:
    RowMajorMatrix(size_t N);
    ~RowMajorMatrix() override = default;

    float* get_data() const override;
    float get(size_t i, size_t j) const override;
    void set(size_t i, size_t j, float val) override;
};

class RowMajorSystem : public MatrixSystem {
private:
    RowMajorMatrix src_, dst_;
public:
    RowMajorSystem(size_t N);
    void initialize() override;
    void transpose() override;
    RowMajorMatrix& get_src() override;
    RowMajorMatrix& get_dst() override;
};

#endif
