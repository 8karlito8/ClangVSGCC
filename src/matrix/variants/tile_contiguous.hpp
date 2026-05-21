#ifndef TILE_CONTIGUOUS_HPP
#define TILE_CONTIGUOUS_HPP

#include "matrix_base.hpp"
#include <vector>

class TileContiguousMatrix : public Matrix {
private:
    std::vector<float> data_;
    size_t tile_row_count_;
    size_t tile_col_count_;

    inline size_t tile_index(size_t i, size_t j) const;

public:
    TileContiguousMatrix(size_t N);
    ~TileContiguousMatrix() override = default;

    float* get_data() const override;
    float get(size_t i, size_t j) const override;
    void set(size_t i, size_t j, float val) override;
};

class TileContiguousSystem : public MatrixSystem {
private:
    TileContiguousMatrix src_, dst_;
public:
    TileContiguousSystem(size_t N);
    void initialize() override;
    void transpose() override;
    TileContiguousMatrix& get_src() override;
    TileContiguousMatrix& get_dst() override;
};

#endif
