#include "vx_utils.h"
#include <iostream>
#include <fstream>
#include <list>
#include <cstring>
#include <vortex.h>
#include <VX_config.h>
#include <VX_types.h>
#include <assert.h>

uint64_t aligned_size(uint64_t size, uint64_t alignment) {        
    assert(0 == (alignment & (alignment - 1)));
    return (size + alignment - 1) & ~(alignment - 1);
}

bool is_aligned(uint64_t addr, uint64_t alignment) {
    assert(0 == (alignment & (alignment - 1)));
    return 0 == (addr & (alignment - 1));
}

///////////////////////////////////////////////////////////////////////////////

class AutoPerfDump {
public:
    AutoPerfDump() : perf_class_(0) {}

    ~AutoPerfDump() {
      for (auto device : devices_) {
        vx_dump_perf(device, stdout);
      }
    }

    void add_device(vx_device_h device) {
      auto perf_class_s = getenv ("PERF_CLASS");
      if (perf_class_s) {
        perf_class_ = std::atoi(perf_class_s);
        vx_dcr_write(device, DCR_MPM_CLASS, perf_class_);
      }
      devices_.push_back(device);
    }

    void remove_device(vx_device_h device) {
      devices_.remove(device);
      vx_dump_perf(device, stdout);
    }

    int get_perf_class() const {
      return perf_class_;
    }
    
private:
    std::list<vx_device_h> devices_;
    int perf_class_;
};

#ifdef DUMP_PERF_STATS
AutoPerfDump gAutoPerfDump;
#endif

void perf_add_device(vx_device_h device) {
#ifdef DUMP_PERF_STATS
  gAutoPerfDump.add_device(device);
#endif
}

void perf_remove_device(vx_device_h device) {
#ifdef DUMP_PERF_STATS
  gAutoPerfDump.remove_device(device);
#endif
}

///////////////////////////////////////////////////////////////////////////////

extern int vx_upload_kernel_bytes(vx_device_h device, const void* content, uint64_t size) {
  int err = 0;

  if (NULL == content || 0 == size)
    return -1;

  uint32_t buffer_transfer_size = 65536; // 64 KB
  uint64_t kernel_base_addr;
  err = vx_dev_caps(device, VX_CAPS_KERNEL_BASE_ADDR, &kernel_base_addr);
  if (err != 0)
    return -1;

  // allocate device buffer
  vx_buffer_h buffer;
  err = vx_buf_alloc(device, buffer_transfer_size, &buffer);
  if (err != 0)
    return -1; 

  // get buffer address
  auto buf_ptr = (uint8_t*)vx_host_ptr(buffer);

  //
  // upload content
  //

  uint64_t offset = 0;
  while (offset < size) {
    auto chunk_size = std::min<uint64_t>(buffer_transfer_size, size - offset);
    std::memcpy(buf_ptr, (uint8_t*)content + offset, chunk_size);

    /*printf("***  Upload Kernel to 0x%0x: data=", kernel_base_addr + offset);
    for (int i = 0, n = ((chunk_size+7)/8); i < n; ++i) {
      printf("%08x", ((uint64_t*)((uint8_t*)content + offset))[n-1-i]);
    }
    printf("\n");*/

    err = vx_copy_to_dev(buffer, kernel_base_addr + offset, chunk_size, 0);
    if (err != 0) {
      vx_buf_free(buffer);
      return err;
    }
    offset += chunk_size;
  }

  vx_buf_free(buffer);

  return 0;
}

extern int vx_upload_kernel_file(vx_device_h device, const char* filename) {
  std::ifstream ifs(filename);
  if (!ifs) {
    std::cout << "error: " << filename << " not found" << std::endl;
    return -1;
  }

  // read file content
  ifs.seekg(0, ifs.end);
  auto size = ifs.tellg();
  auto content = new char [size];   
  ifs.seekg(0, ifs.beg);
  ifs.read(content, size);

  // upload
  int err = vx_upload_kernel_bytes(device, content, size);

  // release buffer
  delete[] content;

  return err;
}

///////////////////////////////////////////////////////////////////////////////

/*static uint32_t get_csr_32(const uint32_t* buffer, int addr) {
  uint32_t value_lo = buffer[addr - CSR_MPM_BASE];
  return value_lo;
}*/

static uint64_t get_csr_64(const uint32_t* buffer, int addr) {
  uint32_t value_lo = buffer[addr - CSR_MPM_BASE];
  uint32_t value_hi = buffer[addr - CSR_MPM_BASE + 32];
  return (uint64_t(value_hi) << 32) | value_lo;
}

extern int vx_dump_perf(vx_device_h device, FILE* stream) {
  int ret = 0;

  uint64_t instrs = 0;
  uint64_t cycles = 0;

#ifdef PERF_ENABLE   
  auto perf_class = gAutoPerfDump.get_perf_class();

  // PERF: pipeline stalls
  uint64_t ibuffer_stalls = 0;
  uint64_t scoreboard_stalls = 0;
  uint64_t lsu_stalls = 0;
  uint64_t fpu_stalls = 0;
  uint64_t csr_stalls = 0;
  uint64_t alu_stalls = 0;
  uint64_t gpu_stalls = 0;
  // PERF: decode
  uint64_t loads = 0;
  uint64_t stores = 0;
  uint64_t branches = 0;
  // PERF: Icache 
  uint64_t icache_reads = 0;
  uint64_t icache_read_misses = 0;
  // PERF: Dcache 
  uint64_t dcache_reads = 0;
  uint64_t dcache_writes = 0;
  uint64_t dcache_read_misses = 0;
  uint64_t dcache_write_misses = 0;
  uint64_t dcache_bank_stalls = 0;  
  uint64_t dcache_mshr_stalls = 0;
  // PERF: shared memory
  uint64_t smem_reads = 0;
  uint64_t smem_writes = 0;
  uint64_t smem_bank_stalls = 0;
  // PERF: memory
  uint64_t mem_reads = 0;
  uint64_t mem_writes = 0;
  uint64_t mem_lat = 0;
#ifdef EXT_TEX_ENABLE
  // PERF: texunit
  uint64_t tex_mem_reads = 0;
  uint64_t tex_mem_lat = 0;
#endif
#ifdef EXT_ROP_ENABLE
  uint64_t rop_mem_reads;
  uint64_t rop_mem_writes;
  uint64_t rop_mem_lat;
  uint64_t rop_idle_cycles;
  uint32_t rop_stall_cycles;
  // PERF: rop ocache
  uint64_t rop_ocache_reads;       
  uint64_t rop_ocache_writes;      
  uint64_t rop_ocache_read_misses; 
  uint64_t rop_ocache_write_misses;
  uint64_t rop_ocache_bank_stalls; 
  uint64_t rop_ocache_mshr_stalls; 
  uint64_t rop_ocache_mem_stalls;  
  uint64_t rop_ocache_crsp_stalls;
#endif
#ifdef EXT_RASTER_ENABLE
  uint64_t raster_mem_reads;
  uint64_t raster_mem_lat;
  // PERF: raster cache
  uint64_t rcache_reads;  
  uint64_t rcache_read_misses;
  uint64_t rcache_bank_stalls;
#endif
#endif

  uint64_t num_cores;
  ret = vx_dev_caps(device, VX_CAPS_MAX_CORES, &num_cores);
  if (ret != 0)
    return ret;

  uint64_t mpm_mem_size = 64 * sizeof(uint32_t);

  vx_buffer_h staging_buf;
  ret = vx_buf_alloc(device, mpm_mem_size, &staging_buf);
  if (ret != 0)
    return ret;

  auto staging_ptr = (uint32_t*)vx_host_ptr(staging_buf);
      
  for (unsigned core_id = 0; core_id < num_cores; ++core_id) {    
    uint64_t mpm_mem_addr = IO_CSR_ADDR + core_id * mpm_mem_size;    
    ret = vx_copy_from_dev(staging_buf, mpm_mem_addr, mpm_mem_size, 0);
    if (ret != 0) {
      vx_buf_free(staging_buf);
      return ret;
    }

    uint64_t instrs_per_core = get_csr_64(staging_ptr, CSR_MINSTRET);
    uint64_t cycles_per_core = get_csr_64(staging_ptr, CSR_MCYCLE);
    float IPC = (float)(double(instrs_per_core) / double(cycles_per_core));
    if (num_cores > 1) fprintf(stream, "PERF: core%d: instrs=%ld, cycles=%ld, IPC=%f\n", core_id, instrs_per_core, cycles_per_core, IPC);            
    instrs += instrs_per_core;
    cycles = std::max<uint64_t>(cycles_per_core, cycles);

  #ifdef PERF_ENABLE
    switch (perf_class) {
    case DCR_MPM_CLASS_CORE: {
      // PERF: pipeline    
      // ibuffer_stall
      uint64_t ibuffer_stalls_per_core = get_csr_64(staging_ptr, CSR_MPM_IBUF_ST);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: ibuffer stalls=%ld\n", core_id, ibuffer_stalls_per_core);
      ibuffer_stalls += ibuffer_stalls_per_core;
      // scoreboard_stall
      uint64_t scoreboard_stalls_per_core = get_csr_64(staging_ptr, CSR_MPM_SCRB_ST);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: scoreboard stalls=%ld\n", core_id, scoreboard_stalls_per_core);
      scoreboard_stalls += scoreboard_stalls_per_core;
      // alu_stall
      uint64_t alu_stalls_per_core = get_csr_64(staging_ptr, CSR_MPM_ALU_ST);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: alu unit stalls=%ld\n", core_id, alu_stalls_per_core);
      alu_stalls += alu_stalls_per_core;      
      // lsu_stall
      uint64_t lsu_stalls_per_core = get_csr_64(staging_ptr, CSR_MPM_LSU_ST);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: lsu unit stalls=%ld\n", core_id, lsu_stalls_per_core);
      lsu_stalls += lsu_stalls_per_core;
      // csr_stall
      uint64_t csr_stalls_per_core = get_csr_64(staging_ptr, CSR_MPM_CSR_ST);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: csr unit stalls=%ld\n", core_id, csr_stalls_per_core);
      csr_stalls += csr_stalls_per_core;    
      // fpu_stall
      uint64_t fpu_stalls_per_core = get_csr_64(staging_ptr, CSR_MPM_FPU_ST);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: fpu unit stalls=%ld\n", core_id, fpu_stalls_per_core);
      fpu_stalls += fpu_stalls_per_core;      
      // gpu_stall
      uint64_t gpu_stalls_per_core = get_csr_64(staging_ptr, CSR_MPM_GPU_ST);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: gpu unit stalls=%ld\n", core_id, gpu_stalls_per_core);
      gpu_stalls += gpu_stalls_per_core;  

      // PERF: decode
      // loads
      uint64_t loads_per_core = get_csr_64(staging_ptr, CSR_MPM_LOADS);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: loads=%ld\n", core_id, loads_per_core);
      loads += loads_per_core;
      // stores
      uint64_t stores_per_core = get_csr_64(staging_ptr, CSR_MPM_STORES);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: stores=%ld\n", core_id, stores_per_core);
      stores += stores_per_core;
      // branches
      uint64_t branches_per_core = get_csr_64(staging_ptr, CSR_MPM_BRANCHES);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: branches=%ld\n", core_id, branches_per_core);
      branches += branches_per_core;

      // PERF: Icache
      // total reads
      uint64_t icache_reads_per_core = get_csr_64(staging_ptr, CSR_MPM_ICACHE_READS);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: icache reads=%ld\n", core_id, icache_reads_per_core);
      icache_reads += icache_reads_per_core;
      // read misses
      uint64_t icache_miss_r_per_core = get_csr_64(staging_ptr, CSR_MPM_ICACHE_MISS_R);
      int icache_read_hit_ratio = (int)((1.0 - (double(icache_miss_r_per_core) / double(icache_reads_per_core))) * 100);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: icache misses=%ld (hit ratio=%d%%)\n", core_id, icache_miss_r_per_core, icache_read_hit_ratio);
      icache_read_misses += icache_miss_r_per_core;

      // PERF: Dcache
      // total reads
      uint64_t dcache_reads_per_core = get_csr_64(staging_ptr, CSR_MPM_DCACHE_READS);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: dcache reads=%ld\n", core_id, dcache_reads_per_core);
      dcache_reads += dcache_reads_per_core;
      // total write
      uint64_t dcache_writes_per_core = get_csr_64(staging_ptr, CSR_MPM_DCACHE_WRITES);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: dcache writes=%ld\n", core_id, dcache_writes_per_core);
      dcache_writes += dcache_writes_per_core;
      // read misses
      uint64_t dcache_miss_r_per_core = get_csr_64(staging_ptr, CSR_MPM_DCACHE_MISS_R);
      int dcache_read_hit_ratio = (int)((1.0 - (double(dcache_miss_r_per_core) / double(dcache_reads_per_core))) * 100);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: dcache read misses=%ld (hit ratio=%d%%)\n", core_id, dcache_miss_r_per_core, dcache_read_hit_ratio);
      dcache_read_misses += dcache_miss_r_per_core;
      // read misses
      uint64_t dcache_miss_w_per_core = get_csr_64(staging_ptr, CSR_MPM_DCACHE_MISS_W);
      int dcache_write_hit_ratio = (int)((1.0 - (double(dcache_miss_w_per_core) / double(dcache_writes_per_core))) * 100);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: dcache write misses=%ld (hit ratio=%d%%)\n", core_id, dcache_miss_w_per_core, dcache_write_hit_ratio);
      dcache_write_misses += dcache_miss_w_per_core;
      // bank_stalls
      uint64_t dcache_bank_st_per_core = get_csr_64(staging_ptr, CSR_MPM_DCACHE_BANK_ST);
      int dcache_bank_utilization = (int)((double(dcache_reads_per_core + dcache_writes_per_core) / double(dcache_reads_per_core + dcache_writes_per_core + dcache_bank_st_per_core)) * 100);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: dcache bank stalls=%ld (utilization=%d%%)\n", core_id, dcache_bank_st_per_core, dcache_bank_utilization);
      dcache_bank_stalls += dcache_bank_st_per_core;
      // mshr_stalls
      uint64_t dcache_mshr_st_per_core = get_csr_64(staging_ptr, CSR_MPM_DCACHE_MSHR_ST);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: dcache mshr stalls=%ld\n", core_id, dcache_mshr_st_per_core);
      dcache_mshr_stalls += dcache_mshr_st_per_core; 

      // PERF: SMEM
      // total reads
      uint64_t smem_reads_per_core = get_csr_64(staging_ptr, CSR_MPM_SMEM_READS);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: smem reads=%ld\n", core_id, smem_reads_per_core);
      smem_reads += smem_reads_per_core;
      // total write
      uint64_t smem_writes_per_core = get_csr_64(staging_ptr, CSR_MPM_SMEM_WRITES);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: smem writes=%ld\n", core_id, smem_writes_per_core);
      smem_writes += smem_writes_per_core;
      // bank_stalls
      uint64_t smem_bank_st_per_core = get_csr_64(staging_ptr, CSR_MPM_SMEM_BANK_ST);
      int smem_bank_utilization = (int)((double(smem_reads_per_core + smem_writes_per_core) / double(smem_reads_per_core + smem_writes_per_core + smem_bank_st_per_core)) * 100);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: smem bank stalls=%ld (utilization=%d%%)\n", core_id, smem_bank_st_per_core, smem_bank_utilization);
      smem_bank_stalls += smem_bank_st_per_core;

      // PERF: memory
      uint64_t mem_reads_per_core  = get_csr_64(staging_ptr, CSR_MPM_MEM_READS);
      uint64_t mem_writes_per_core = get_csr_64(staging_ptr, CSR_MPM_MEM_WRITES);
      uint64_t mem_lat_per_core    = get_csr_64(staging_ptr, CSR_MPM_MEM_LAT);      
      int mem_avg_lat = (int)(double(mem_lat_per_core) / double(mem_reads_per_core));       
      if (num_cores > 1) fprintf(stream, "PERF: core%d: memory requests=%ld (reads=%ld, writes=%ld)\n", core_id, (mem_reads_per_core + mem_writes_per_core), mem_reads_per_core, mem_writes_per_core);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: memory latency=%d cycles\n", core_id, mem_avg_lat);
      mem_reads  += mem_reads_per_core;
      mem_writes += mem_writes_per_core;
      mem_lat    += mem_lat_per_core;
    } break;
    case DCR_MPM_CLASS_TEX: { 
    #ifdef EXT_TEX_ENABLE
      // total reads
      uint64_t tex_reads_per_core = get_csr_64(staging_ptr, CSR_MPM_TEX_READS);
      if (num_cores > 1) fprintf(stream, "PERF: core%d: tex memory reads=%ld\n", core_id, tex_reads_per_core);
      tex_mem_reads += tex_reads_per_core;
      
      // read latency
      uint64_t tex_lat_per_core = get_csr_64(staging_ptr, CSR_MPM_TEX_LAT);
      int tex_avg_lat = (int)(double(tex_lat_per_core) / double(tex_reads_per_core));
      if (num_cores > 1) fprintf(stream, "PERF: core%d: tex memory latency=%d cycles\n", core_id, tex_avg_lat);
      tex_mem_lat += tex_lat_per_core;
      // <TODO: cache perf counters>

    #endif
    } break;
    case DCR_MPM_CLASS_ROP: {
    #ifdef EXT_ROP_ENABLE
      if (0 == core_id) {
        rop_mem_reads    = get_csr_64(staging_ptr, CSR_MPM_ROP_READS);
        rop_mem_writes   = get_csr_64(staging_ptr, CSR_MPM_ROP_WRITES);
        rop_mem_lat      = get_csr_64(staging_ptr, CSR_MPM_ROP_LAT);
        rop_idle_cycles  = get_csr_64(staging_ptr, CSR_MPM_ROP_IDLE);
        rop_stall_cycles = get_csr_64(staging_ptr, CSR_MPM_ROP_STALL);
        rop_ocache_reads        = get_csr_64(staging_ptr, CSR_MPM_OCACHE_READS);
        rop_ocache_writes       = get_csr_64(staging_ptr, CSR_MPM_OCACHE_WRITES);
        rop_ocache_read_misses  = get_csr_64(staging_ptr, CSR_MPM_OCACHE_MISS_R);
        rop_ocache_write_misses = get_csr_64(staging_ptr, CSR_MPM_OCACHE_MISS_W);
        rop_ocache_bank_stalls  = get_csr_64(staging_ptr, CSR_MPM_OCACHE_BANK_ST);
        rop_ocache_mshr_stalls  = get_csr_64(staging_ptr, CSR_MPM_OCACHE_MSHR_ST);
        rop_ocache_mem_stalls   = get_csr_64(staging_ptr, CSR_MPM_OCACHE_MEM_ST);
        rop_ocache_crsp_stalls  = get_csr_64(staging_ptr, CSR_MPM_OCACHE_CRSP_ST);
      }      
    #endif
    } break;
    case DCR_MPM_CLASS_RASTER: {
    #ifdef EXT_RASTER_ENABLE
      if (0 == core_id) {
        raster_mem_reads      = get_csr_64(staging_ptr, CSR_MPM_RAS_READS);
        raster_mem_lat        = get_csr_64(staging_ptr, CSR_MPM_RAS_LAT);
        rcache_reads          = get_csr_64(staging_ptr, CSR_MPM_RCACHE_READS);
        rcache_read_misses    = get_csr_64(staging_ptr, CSR_MPM_RCACHE_MISS_R);
        rcache_bank_stalls    = get_csr_64(staging_ptr, CSR_MPM_RCACHE_BANK_ST);
      }
    #endif
    } break;
    }
  #endif
  }  
  
  float IPC = (float)(double(instrs) / double(cycles));
  fprintf(stream, "PERF: instrs=%ld, cycles=%ld, IPC=%f\n", instrs, cycles, IPC);    
      
#ifdef PERF_ENABLE
  switch (perf_class) {
  case DCR_MPM_CLASS_CORE: {
    int icache_read_hit_ratio = (int)((1.0 - (double(icache_read_misses) / double(icache_reads))) * 100);
    int dcache_read_hit_ratio = (int)((1.0 - (double(dcache_read_misses) / double(dcache_reads))) * 100);
    int dcache_write_hit_ratio = (int)((1.0 - (double(dcache_write_misses) / double(dcache_writes))) * 100);
    int dcache_bank_utilization = (int)((double(dcache_reads + dcache_writes) / double(dcache_reads + dcache_writes + dcache_bank_stalls)) * 100);
    int smem_bank_utilization = (int)((double(smem_reads + smem_writes) / double(smem_reads + smem_writes + smem_bank_stalls)) * 100);
    int mem_avg_lat = (int)(double(mem_lat) / double(mem_reads));
    fprintf(stream, "PERF: ibuffer stalls=%ld\n", ibuffer_stalls);
    fprintf(stream, "PERF: scoreboard stalls=%ld\n", scoreboard_stalls);
    fprintf(stream, "PERF: alu unit stalls=%ld\n", alu_stalls);
    fprintf(stream, "PERF: lsu unit stalls=%ld\n", lsu_stalls);
    fprintf(stream, "PERF: csr unit stalls=%ld\n", csr_stalls);
    fprintf(stream, "PERF: fpu unit stalls=%ld\n", fpu_stalls);
    fprintf(stream, "PERF: gpu unit stalls=%ld\n", gpu_stalls);
    fprintf(stream, "PERF: loads=%ld\n", loads);
    fprintf(stream, "PERF: stores=%ld\n", stores);
    fprintf(stream, "PERF: branches=%ld\n", branches);
    fprintf(stream, "PERF: icache reads=%ld\n", icache_reads);
    fprintf(stream, "PERF: icache read misses=%ld (hit ratio=%d%%)\n", icache_read_misses, icache_read_hit_ratio);
    fprintf(stream, "PERF: dcache reads=%ld\n", dcache_reads);
    fprintf(stream, "PERF: dcache writes=%ld\n", dcache_writes);
    fprintf(stream, "PERF: dcache read misses=%ld (hit ratio=%d%%)\n", dcache_read_misses, dcache_read_hit_ratio);
    fprintf(stream, "PERF: dcache write misses=%ld (hit ratio=%d%%)\n", dcache_write_misses, dcache_write_hit_ratio);  
    fprintf(stream, "PERF: dcache bank stalls=%ld (utilization=%d%%)\n", dcache_bank_stalls, dcache_bank_utilization);
    fprintf(stream, "PERF: dcache mshr stalls=%ld\n", dcache_mshr_stalls);
    fprintf(stream, "PERF: smem reads=%ld\n", smem_reads);
    fprintf(stream, "PERF: smem writes=%ld\n", smem_writes); 
    fprintf(stream, "PERF: smem bank stalls=%ld (utilization=%d%%)\n", smem_bank_stalls, smem_bank_utilization);
    fprintf(stream, "PERF: memory requests=%ld (reads=%ld, writes=%ld)\n", (mem_reads + mem_writes), mem_reads, mem_writes);
    fprintf(stream, "PERF: memory average latency=%d cycles\n", mem_avg_lat);
  } break;  
  case DCR_MPM_CLASS_TEX: {
  #ifdef EXT_TEX_ENABLE
    int tex_avg_lat = (int)(double(tex_mem_lat) / double(tex_mem_reads));
    fprintf(stream, "PERF: tex memory reads=%ld\n", tex_mem_reads);
    fprintf(stream, "PERF: tex memory latency=%d cycles\n", tex_avg_lat);
    // <TODO: cache perf counters>
  #endif
  } break;
  case DCR_MPM_CLASS_ROP: {
  #ifdef EXT_ROP_ENABLE
    int rop_idle_cycles_ratio = (int)(100 * double(rop_idle_cycles) / cycles);
    int rop_stall_cycles_ratio = (int)(100 * double(rop_stall_cycles) / cycles);
    fprintf(stream, "PERF: rop memory reads=%ld\n", rop_mem_reads);
    fprintf(stream, "PERF: rop memory writes=%ld\n", rop_mem_writes);
    fprintf(stream, "PERF: rop memory latency=%ld\n", rop_mem_lat);
    fprintf(stream, "PERF: rop idle cycles=%d%%\n", rop_idle_cycles_ratio);
    fprintf(stream, "PERF: rop stall cycles=%d%%\n", rop_stall_cycles_ratio);
    // <cache perf counters>
    int ocache_read_hit_ratio = (int)((1.0 - (double(rop_ocache_read_misses) / double(rop_ocache_reads))) * 100);
    int ocache_write_hit_ratio = (int)((1.0 - (double(rop_ocache_write_misses) / double(rop_ocache_writes))) * 100);
    int ocache_bank_utilization = (int)((double(rop_ocache_reads + rop_ocache_writes) / double(rop_ocache_reads + rop_ocache_writes + rop_ocache_bank_stalls)) * 100);
    fprintf(stream, "PERF: ocache reads=%ld\n", rop_ocache_reads);
    fprintf(stream, "PERF: ocache writes=%ld\n", rop_ocache_writes);
    fprintf(stream, "PERF: ocache read misses=%ld (hit ratio=%d%%)\n", rop_ocache_read_misses, ocache_read_hit_ratio);
    fprintf(stream, "PERF: ocache write misses=%ld (hit ratio=%d%%)\n", rop_ocache_write_misses, ocache_write_hit_ratio);  
    fprintf(stream, "PERF: ocache bank stalls=%ld (utilization=%d%%)\n", rop_ocache_bank_stalls, ocache_bank_utilization);
    fprintf(stream, "PERF: ocache mshr stalls=%ld\n", rop_ocache_mshr_stalls);
    fprintf(stream, "PERF: ocache mem stalls=%ld\n", rop_ocache_mem_stalls);
    fprintf(stream, "PERF: ocache crsp stalls=%ld\n", rop_ocache_crsp_stalls);
  #endif
  } break;
  case DCR_MPM_CLASS_RASTER: {
  #ifdef EXT_RASTER_ENABLE
    fprintf(stream, "PERF: raster memory reads=%ld\n", raster_mem_reads);
    fprintf(stream, "PERF: raster memory latency=%ld\n", raster_mem_lat);
    int rcache_read_hit_ratio = (int)((1.0 - (double(rcache_read_misses) / double(rcache_reads))) * 100);
    int rcache_bank_utilization = (int)((double(rcache_reads) / double(rcache_reads + rcache_bank_stalls)) * 100);
    fprintf(stream, "PERF: rcache reads=%ld\n", rcache_reads);
    fprintf(stream, "PERF: rcache read misses=%ld (hit ratio=%d%%)\n", rcache_read_misses, rcache_read_hit_ratio);
    fprintf(stream, "PERF: rcache bank stalls=%ld (utilization=%d%%)\n", rcache_bank_stalls, rcache_bank_utilization);
  #endif
  } break;
  }
#endif

  // release allocated resources
  vx_buf_free(staging_buf);

  return ret;
}

// Deprecated API functions

extern int vx_alloc_shared_mem(vx_device_h hdevice, uint64_t size, vx_buffer_h* hbuffer) {
  return vx_buf_alloc(hdevice, size, hbuffer);
}

extern int vx_buf_release(vx_buffer_h hbuffer) {
  return vx_buf_free(hbuffer);
}

extern int vx_alloc_dev_mem(vx_device_h hdevice, uint64_t size, uint64_t* dev_maddr) {
  return vx_mem_alloc(hdevice, size, dev_maddr);
}