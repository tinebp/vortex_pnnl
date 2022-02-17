#pragma once

#include "types.h"

namespace vortex {

class Core;

struct raster_quad_t {
    uint32_t x;
    uint32_t y;
    uint32_t mask;
    uint32_t pidx;
};

class RasterUnit {
public:
    RasterUnit(Core* core);
    ~RasterUnit();

    void clear();

    uint32_t csr_read(uint32_t addr);
  
    void csr_write(uint32_t addr, uint32_t value);

    bool pop(raster_quad_t* quad);

private:

    std::array<uint32_t, NUM_RASTER_STATES> states_;
    Core* core_;
};

}