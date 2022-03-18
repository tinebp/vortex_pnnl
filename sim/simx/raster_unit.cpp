#include "raster_unit.h"
#include "core.h"
#include <VX_config.h>
#include "mempool.h"
#include <cocogfx/include/fixed.hpp>
#include <cocogfx/include/math.hpp>

using namespace vortex;

#define STAMP_POOL_MAX_SIZE   1024

using fixed16_t = cocogfx::TFixed<16>;
using fixed24_t = cocogfx::TFixed<23>;

using vec2_fx_t = cocogfx::TVector2<fixed16_t>;
using vec3_fx_t = cocogfx::TVector3<fixed16_t>;

using vec2_fx2_t = cocogfx::TVector2<fixed24_t>;
using vec3_fx2_t = cocogfx::TVector3<fixed24_t>;

using rect_u_t = cocogfx::TRect<uint32_t>;

struct primitive_t {
  vec3_fx_t edges[3];
  fixed16_t extents[3];
};

static fixed16_t fxZero(0);

// Evaluate edge function
static fixed16_t evalEdgeFunction(const vec3_fx_t& e, uint32_t x, uint32_t y) {
  return (e.x * x) + (e.y * y) + e.z;
}

// Calculate the edge extents for square corners
static fixed16_t calcEdgeExtents(const vec3_fx_t& e) {
  vec2_fx_t corners[4] = {{fxZero, fxZero},  // 00
                          {e.x,    fxZero},  // 10
                          {fxZero, e.y},     // 01
                          {e.x,    e.y}};    // 11
  auto i = (e.y >= fxZero) ? ((e.x >= fxZero) ? 3 : 2) : (e.x >= fxZero) ? 1 : 0;
  return corners[i].x + corners[i].y;
}

class Rasterizer {
private:    
  const Arch& arch_;
  const RasterUnit::DCRS& dcrs_;
  RAM* mem_;
  uint32_t tile_logsize_;
  uint32_t block_logsize_;    
  uint32_t num_tiles_;
  uint32_t tbuf_baseaddr_;    
  uint32_t pbuf_baseaddr_;
  uint32_t pbuf_stride_;
  uint32_t tbuf_addr_;
  uint32_t dst_width_;
  uint32_t dst_height_;
  uint32_t tile_x_;
  uint32_t tile_y_;
  uint32_t num_prims_;    
  uint32_t cur_tile_;
  uint32_t cur_prim_;
  uint32_t pid_;
  RasterUnit::Stamp* stamps_head_;
  RasterUnit::Stamp *stamps_tail_;
  uint32_t           stamps_size_;
  bool initialized_;  

  void stamps_push(RasterUnit::Stamp* stamp) {
    assert(stamp);
    stamp->next_ = stamps_tail_;
    stamp->prev_ = nullptr;
    if (stamps_tail_)
      stamps_tail_->prev_ = stamp;
    else
      stamps_head_ = stamp;
    stamps_tail_ = stamp;
    ++stamps_size_;
  }

  void stamps_pop() {
    assert (stamps_size_);
    stamps_head_ = stamps_head_->prev_;
    if (stamps_head_)
      stamps_head_->next_ = nullptr;
    else
      stamps_tail_ = nullptr;
    --stamps_size_;
  }

  void renderQuad(const primitive_t& primitive, 
                  uint32_t  x, 
                  uint32_t  y, 
                  fixed16_t e0, 
                  fixed16_t e1, 
                  fixed16_t e2) {
    uint32_t mask = 0;
    std::array<vec3_fx_t, 4> bcoords;

    for (uint32_t j = 0; j < 2; ++j) {
      auto ee0 = e0;
      auto ee1 = e1;
      auto ee2 = e2;
      for (uint32_t i = 0; i < 2; ++i) {
        // test if pixel overlaps triangle
        if (ee0 >= fxZero && ee1 >= fxZero && ee2 >= fxZero) {
          // test if the pixel overlaps rendering region
          if ((x+i) < dst_width_ && (y+j) < dst_height_) {
            uint32_t f = j * 2 + i;          
            mask |= (1 << f);                
            bcoords[f].x = ee0;
            bcoords[f].y = ee1;
            bcoords[f].z = ee2;          
          }
        }
        // update edge equation x components
        ee0 += primitive.edges[0].x;
        ee1 += primitive.edges[1].x;
        ee2 += primitive.edges[2].x;
      }
      // update edge equation y components
      e0 += primitive.edges[0].y;
      e1 += primitive.edges[1].y;
      e2 += primitive.edges[2].y;
    }
    
    if (mask) {
      // add stamp to queue
      //printf("Quad: x=%d, y=%d, mask=%d, pid=%d\n", x, y, mask, pid_);
      this->stamps_push(new RasterUnit::Stamp(x, y, mask, bcoords, pid_));
    }
  }

  void renderBlock(uint32_t subBlockLogSize, 
                   const primitive_t& primitive, 
                   uint32_t  x, 
                   uint32_t  y, 
                   fixed16_t e0, 
                   fixed16_t e1, 
                   fixed16_t e2) {
    // check if block overlap triangle    
    if ((e0 + (primitive.extents[0] << subBlockLogSize)) < fxZero 
     || (e1 + (primitive.extents[1] << subBlockLogSize)) < fxZero
     || (e2 + (primitive.extents[2] << subBlockLogSize)) < fxZero)
      return; 
  
    if (subBlockLogSize > 1) {
      //printf("Block (%d,%d) :\n", x, y);

      --subBlockLogSize;
      auto subBlockSize = 1 << subBlockLogSize;
      // draw top-left subtile
      {
        auto sx  = x;
        auto sy  = y;
        auto se0 = e0;
        auto se1 = e1;
        auto se2 = e2;
        this->renderBlock(subBlockLogSize, primitive, sx, sy, se0, se1, se2);
      }

      // draw top-right subtile
      {
        auto sx  = x + subBlockSize;
        auto sy  = y;
        auto se0 = e0 + (primitive.edges[0].x << subBlockLogSize);
        auto se1 = e1 + (primitive.edges[1].x << subBlockLogSize);
        auto se2 = e2 + (primitive.edges[2].x << subBlockLogSize);
        this->renderBlock(subBlockLogSize, primitive, sx, sy, se0, se1, se2);
      }

      // draw bottom-left subtile
      {
        auto sx  = x;
        auto sy  = y + subBlockSize;
        auto se0 = e0 + (primitive.edges[0].y << subBlockLogSize);
        auto se1 = e1 + (primitive.edges[1].y << subBlockLogSize);
        auto se2 = e2 + (primitive.edges[2].y << subBlockLogSize);
        this->renderBlock(subBlockLogSize, primitive, sx, sy, se0, se1, se2);
      }

      // draw bottom-right subtile
      {
        auto sx  = x + subBlockSize;
        auto sy  = y + subBlockSize;
        auto se0 = e0 + (primitive.edges[0].x << subBlockLogSize) + (primitive.edges[0].y << subBlockLogSize);
        auto se1 = e1 + (primitive.edges[1].x << subBlockLogSize) + (primitive.edges[1].y << subBlockLogSize);
        auto se2 = e2 + (primitive.edges[2].x << subBlockLogSize) + (primitive.edges[2].y << subBlockLogSize);
        this->renderBlock(subBlockLogSize, primitive, sx, sy, se0, se1, se2);
      }
    } else {
      // draw low-level block
      this->renderQuad(primitive, x, y, e0, e1, e2);
    }
  }

  void renderTile(uint32_t subTileLogSize, 
                  const primitive_t& primitive, 
                  uint32_t  x, 
                  uint32_t  y, 
                  fixed16_t e0, 
                  fixed16_t e1, 
                  fixed16_t e2) {
    // check if tile overlap triangle    
    if ((e0 + (primitive.extents[0] << subTileLogSize)) < fxZero 
     || (e1 + (primitive.extents[1] << subTileLogSize)) < fxZero
     || (e2 + (primitive.extents[2] << subTileLogSize)) < fxZero)
      return; 
    
    if (subTileLogSize > block_logsize_) {
      //printf("Tile (%d,%d) :\n", x, y);

      --subTileLogSize;
      auto subTileSize = 1 << subTileLogSize;
      // draw top-left subtile
      {
        auto sx  = x;
        auto sy  = y;
        auto se0 = e0;
        auto se1 = e1;
        auto se2 = e2;
        this->renderTile(subTileLogSize, primitive, sx, sy, se0, se1, se2);
      }

      // draw top-right subtile
      {
        auto sx  = x + subTileSize;
        auto sy  = y;
        auto se0 = e0 + (primitive.edges[0].x << subTileLogSize);
        auto se1 = e1 + (primitive.edges[1].x << subTileLogSize);
        auto se2 = e2 + (primitive.edges[2].x << subTileLogSize);
        this->renderTile(subTileLogSize, primitive, sx, sy, se0, se1, se2);
      }

      // draw bottom-left subtile
      {
        auto sx  = x;
        auto sy  = y + subTileSize;
        auto se0 = e0 + (primitive.edges[0].y << subTileLogSize);
        auto se1 = e1 + (primitive.edges[1].y << subTileLogSize);
        auto se2 = e2 + (primitive.edges[2].y << subTileLogSize);
        this->renderTile(subTileLogSize, primitive, sx, sy, se0, se1, se2);
      }

      // draw bottom-right subtile
      {
        auto sx  = x + subTileSize;
        auto sy  = y + subTileSize;
        auto se0 = e0 + (primitive.edges[0].x << subTileLogSize) + (primitive.edges[0].y << subTileLogSize);
        auto se1 = e1 + (primitive.edges[1].x << subTileLogSize) + (primitive.edges[1].y << subTileLogSize);
        auto se2 = e2 + (primitive.edges[2].x << subTileLogSize) + (primitive.edges[2].y << subTileLogSize);
        this->renderTile(subTileLogSize, primitive, sx, sy, se0, se1, se2);
      }
    } else {
      if (block_logsize_ > 1) {
        // draw low-level block
        this->renderBlock(subTileLogSize, primitive, x, y, e0, e1, e2);
      } else {
        // draw low-level quad
        this->renderQuad(primitive, x, y, e0, e1, e2);
      }
    }
  }

  void initialize() {
    // get device configuration
    num_tiles_     = dcrs_.read(DCR_RASTER_TILE_COUNT);
    tbuf_baseaddr_ = dcrs_.read(DCR_RASTER_TBUF_ADDR);
    pbuf_baseaddr_ = dcrs_.read(DCR_RASTER_PBUF_ADDR);
    pbuf_stride_   = dcrs_.read(DCR_RASTER_PBUF_STRIDE);
    dst_width_     = dcrs_.read(DCR_RASTER_DST_SIZE) & 0xffff;
    dst_height_    = dcrs_.read(DCR_RASTER_DST_SIZE) >> 16;

    tbuf_addr_ = tbuf_baseaddr_;
    cur_tile_  = 0;
    cur_prim_  = 0;
    num_prims_ = 0;      
    
    initialized_ = true;
  }

  void renderNextPrimitive() {    
    if (0 == num_prims_) {
      // read next tile header from tile buffer
      uint32_t tile_xy;
      mem_->read(&tile_xy, tbuf_addr_, 4);
      tbuf_addr_ += 4;
      mem_->read(&num_prims_, tbuf_addr_, 4);
      tbuf_addr_ += 4;
      assert(num_prims_ > 0);
      tile_x_ = (tile_xy & 0xffff) << tile_logsize_;
      tile_y_ = (tile_xy >> 16) << tile_logsize_;
      cur_prim_ = 0;
    }

    // read next primitive index from tile buffer
    mem_->read(&pid_, tbuf_addr_, 4);
    tbuf_addr_ += 4;

    uint32_t x = tile_x_;
    uint32_t y = tile_y_;

    //printf("renderNextPrimitive(tile=%d/%d, prim=%d/%d, pid=%d, tx=%d, ty=%d)\n", cur_tile_, num_tiles_, cur_prim_, num_prims_, pid_, x, y);

    // get primitive edges
    primitive_t primitive;
    auto pbuf_addr = pbuf_baseaddr_ + pid_ * pbuf_stride_;
    for (int i = 0; i < 3; ++i) {
      mem_->read(&primitive.edges[i].x, pbuf_addr, 4);
      pbuf_addr += 4;
      mem_->read(&primitive.edges[i].y, pbuf_addr, 4);
      pbuf_addr += 4;
      mem_->read(&primitive.edges[i].z, pbuf_addr, 4);
      pbuf_addr += 4;
    }

    //printf("edge0=(%d, %d, %d)\n", primitive.edges[0].x.data(), primitive.edges[0].y.data(), primitive.edges[0].z.data());
    //printf("edge1=(%d, %d, %d)\n", primitive.edges[1].x.data(), primitive.edges[1].y.data(), primitive.edges[1].z.data());
    //printf("edge2=(%d, %d, %d)\n", primitive.edges[2].x.data(), primitive.edges[2].y.data(), primitive.edges[2].z.data());

    // Add tile corner edge offsets
    primitive.extents[0] = calcEdgeExtents(primitive.edges[0]);
    primitive.extents[1] = calcEdgeExtents(primitive.edges[1]);
    primitive.extents[2] = calcEdgeExtents(primitive.edges[2]);

    // Evaluate edge equation for the starting tile
    auto e0 = evalEdgeFunction(primitive.edges[0], x, y);
    auto e1 = evalEdgeFunction(primitive.edges[1], x, y);
    auto e2 = evalEdgeFunction(primitive.edges[2], x, y);

    // Render the tile
    if (tile_logsize_ > block_logsize_) {
      this->renderTile(tile_logsize_, primitive, x, y, e0, e1, e2);
    } else {
      this->renderBlock(block_logsize_, primitive, x, y, e0, e1, e2);
    }

    // Move to next primitive
    ++cur_prim_;
    if (cur_prim_ == num_prims_) {
      // Move to next tile      
      ++cur_tile_;
      num_prims_ = 0;
    }

    //printf("*** generated %d stamps\n", stamps_size_);
  }

public:
  Rasterizer(const Arch& arch,
              const RasterUnit::DCRS& dcrs, 
              uint32_t tile_logsize, 
              uint32_t block_logsize) 
    : arch_(arch)
    , dcrs_(dcrs)
    , tile_logsize_(tile_logsize)
    , block_logsize_(block_logsize)
    , stamps_head_(nullptr)
    , stamps_tail_(nullptr)
    , stamps_size_(0)
    , initialized_(false) {
    assert(block_logsize >= 1);
    assert(tile_logsize >= block_logsize);
  }

  ~Rasterizer() {
    //--
  }

  void clear() {
    initialized_ = false;
  }  

  void attach_ram(RAM* mem) {
    mem_ = mem;
  }

  RasterUnit::Stamp* fetch() {      
    if (!initialized_) {
      this->initialize();
    }
    
    do {
      if (stamps_head_ == nullptr && cur_tile_ == num_tiles_)
        return nullptr;
      if (stamps_head_ == nullptr) {
        this->renderNextPrimitive();
      }      
    } while (stamps_head_ == nullptr);
    
    auto stamp = stamps_head_;
    this->stamps_pop();
    return stamp;
  }
};

class RasterUnit::Impl {
private:
  RasterUnit* simobject_;        
  const Arch& arch_;
  Rasterizer rasterizer_;
  PerfStats perf_stats_;

public:
  Impl(RasterUnit* simobject,     
       const Arch &arch,
       const DCRS& dcrs, 
       uint32_t tile_logsize, 
       uint32_t block_logsize) 
    : simobject_(simobject)
    , arch_(arch)
    , rasterizer_(arch, dcrs, tile_logsize, block_logsize)
  {}

  ~Impl() {}

  void clear() {
    rasterizer_.clear();
  }  

  void attach_ram(RAM* mem) {
    rasterizer_.attach_ram(mem);
  }

  RasterUnit::Stamp* fetch() {      
    return rasterizer_.fetch();
  }

  void tick() {
    //--
  }

  const PerfStats& perf_stats() const { 
    return perf_stats_; 
  }
};

///////////////////////////////////////////////////////////////////////////////

RasterUnit::RasterUnit(const SimContext& ctx, 
                       const char* name,                        
                       const Arch &arch, 
                       const DCRS& dcrs,
                       uint32_t tile_logsize, 
                       uint32_t block_logsize) 
  : SimObject<RasterUnit>(ctx, name)
  , Input(this)
  , Output(this)
  , impl_(new Impl(this, arch, dcrs, tile_logsize, block_logsize)) 
{}

RasterUnit::~RasterUnit() {
  delete impl_;
}

void RasterUnit::reset() {
  impl_->clear();
}

void RasterUnit::attach_ram(RAM* mem) {
  impl_->attach_ram(mem);
}

RasterUnit::Stamp* RasterUnit::fetch() {
  return impl_->fetch();
}

void RasterUnit::tick() {
  impl_->tick();
}

const RasterUnit::PerfStats& RasterUnit::perf_stats() const {
  return impl_->perf_stats();
}