#include "exeunit.h"
#include <iostream>
#include <iomanip>
#include <string.h>
#include <assert.h>
#include <util.h>
#include "debug.h"
#include "core.h"
#include "constants.h"
#include "cachesim.h"

using namespace vortex;

NopUnit::NopUnit(const SimContext& ctx, Core* core) : ExeUnit(ctx, core, "NOP") {}
    
void NopUnit::tick() {
    if (Input.empty()) 
        return;
    auto trace = Input.front();
    Output.send(trace, 1);
    Input.pop();
}

///////////////////////////////////////////////////////////////////////////////

LsuUnit::LsuUnit(const SimContext& ctx, Core* core) 
    : ExeUnit(ctx, core, "LSU")
    , dcache_(core->dcache_)
    , pending_rd_reqs_(LSUQ_SIZE)
    , num_threads_(core->arch().num_threads())     
    , fence_lock_(false)
{}

void LsuUnit::reset() {
    pending_rd_reqs_.clear();
    fence_lock_ = false;
}

void LsuUnit::tick() {
    // handle dcache response
    for (uint32_t t = 0; t < num_threads_; ++t) {
        auto& dcache_rsp_port = dcache_->CoreRspPorts.at(t);
        if (dcache_rsp_port.empty())
            continue;
        auto& mem_rsp = dcache_rsp_port.front();
        auto& entry = pending_rd_reqs_.at(mem_rsp.tag);          
        auto trace = entry.trace;
        DT(3, "dcache-rsp: tag=" << mem_rsp.tag << ", type=" << trace->lsu_type 
            << ", tid=" << t << ", " << *trace);  
        assert(entry.count);
        --entry.count; // track remaining blocks 
        if (0 == entry.count) {
            Output.send(trace, 1);
            pending_rd_reqs_.release(mem_rsp.tag);
        } 
        dcache_rsp_port.pop();  
    }

    // handle shared memory response
    for (uint32_t t = 0; t < num_threads_; ++t) {
        auto& smem_rsp_port = core_->sharedmem_->Outputs.at(t);
        if (smem_rsp_port.empty())
            continue;
        auto& mem_rsp = smem_rsp_port.front();
        auto& entry = pending_rd_reqs_.at(mem_rsp.tag);          
        auto trace = entry.trace;
        DT(3, "smem-rsp: tag=" << mem_rsp.tag << ", type=" << trace->lsu_type 
            << ", tid=" << t << ", " << *trace);  
        assert(entry.count);
        --entry.count; // track remaining blocks 
        if (0 == entry.count) {
            Output.send(trace, 1);
            pending_rd_reqs_.release(mem_rsp.tag);
        } 
        smem_rsp_port.pop();  
    }

    if (fence_lock_) {
        // wait for all pending memory operations to complete
        if (!pending_rd_reqs_.empty())
            return;
        Output.send(fence_state_, 1);
        fence_lock_ = false;
        DT(3, "fence-unlock: " << fence_state_);
    }

    // check input queue
    if (Input.empty())
        return;

    auto trace = Input.front();
    auto trace_data = dynamic_cast<LsuTraceData*>(trace->data);

    if (trace->lsu_type == LsuType::FENCE) {
        // schedule fence lock
        fence_state_ = trace;
        fence_lock_ = true;        
        DT(3, "fence-lock: " << *trace);
        // remove input
        auto time = Input.pop(); 
        core_->perf_stats_.lsu_stalls += (SimPlatform::instance().cycles() - time);
        return;
    }

    // check pending queue capacity    
    if (pending_rd_reqs_.full()) {
        if (!trace->suspend()) {
            DT(3, "*** lsu-queue-stall: " << *trace);
        }
        return;
    } else {
        trace->resume();
    }
    
    bool is_write = (trace->lsu_type == LsuType::STORE);

    // duplicates detection
    bool is_dup = false;
    if (trace->tmask.test(0)) {
        uint64_t addr_mask = sizeof(uint32_t)-1;
        uint32_t addr0 = trace_data->mem_addrs.at(0).addr & ~addr_mask;
        uint32_t matches = 1;
        for (uint32_t t = 1; t < num_threads_; ++t) {
            if (!trace->tmask.test(t))
                continue;
            auto mem_addr = trace_data->mem_addrs.at(t).addr & ~addr_mask;
            matches += (addr0 == mem_addr);
        }
        is_dup = (matches == trace->tmask.count());
    }

    uint32_t addr_count;
    if (is_dup) {
        addr_count = 1;
    } else {
        addr_count = trace->tmask.count();
    }

    auto tag = pending_rd_reqs_.allocate({trace, addr_count});

    for (uint32_t t = 0; t < num_threads_; ++t) {
        if (!trace->tmask.test(t))
            continue;
        
        auto& dcache_req_port = dcache_->CoreReqPorts.at(t);
        auto mem_addr = trace_data->mem_addrs.at(t);
        auto type = core_->get_addr_type(mem_addr.addr);

        MemReq mem_req;
        mem_req.addr  = mem_addr.addr;
        mem_req.write = is_write;
        mem_req.non_cacheable = (type == AddrType::IO); 
        mem_req.tag   = tag;
        mem_req.core_id = trace->cid;
        mem_req.uuid = trace->uuid;
        
        if (type == AddrType::Shared) {
            core_->sharedmem_->Inputs.at(t).send(mem_req, 2);
            DT(3, "smem-req: addr=" << std::hex << mem_req.addr << ", tag=" << tag 
                << ", type=" << trace->lsu_type << ", tid=" << t << ", " << *trace);
        } else {            
            dcache_req_port.send(mem_req, 2);
            DT(3, "dcache-req: addr=" << std::hex << mem_req.addr << ", tag=" << tag 
                << ", type=" << trace->lsu_type << ", tid=" << t << ", nc=" << mem_req.non_cacheable << ", " << *trace);
        }        
        
        if (is_dup)
            break;
    }

    // do not wait on writes
    if (is_write) {
        pending_rd_reqs_.release(tag);
        Output.send(trace, 1);
    }

    // remove input
    auto time = Input.pop();
    core_->perf_stats_.lsu_stalls += (SimPlatform::instance().cycles() - time);
}

///////////////////////////////////////////////////////////////////////////////

AluUnit::AluUnit(const SimContext& ctx, Core* core) : ExeUnit(ctx, core, "ALU") {}
    
void AluUnit::tick() {    
    if (Input.empty())
        return;
    auto trace = Input.front();    
    switch (trace->alu_type) {
    case AluType::ARITH:        
    case AluType::BRANCH:
    case AluType::SYSCALL:
    case AluType::CMOV:
        Output.send(trace, 1);
        break;
    case AluType::IMADD:
        Output.send(trace, 1);
        break;
    case AluType::IMUL:
        Output.send(trace, LATENCY_IMUL+1);
        break;
    case AluType::IDIV:
        Output.send(trace, XLEN+1);
        break;
    default:
        std::abort();
    }
    DT(3, "pipeline-execute: op=" << trace->alu_type << ", " << *trace);
    if (trace->fetch_stall) {
        core_->stalled_warps_.reset(trace->wid);
    }
    auto time = Input.pop();
    core_->perf_stats_.alu_stalls += (SimPlatform::instance().cycles() - time);
}

///////////////////////////////////////////////////////////////////////////////

CsrUnit::CsrUnit(const SimContext& ctx, Core* core) : ExeUnit(ctx, core, "CSR") {}
    
void CsrUnit::tick() {
    if (Input.empty()) 
        return;
    auto trace = Input.front();
    Output.send(trace, 1);
    auto time = Input.pop();
    core_->perf_stats_.csr_stalls += (SimPlatform::instance().cycles() - time);
    DT(3, "pipeline-execute: op=CSR, " << *trace);
}

///////////////////////////////////////////////////////////////////////////////

FpuUnit::FpuUnit(const SimContext& ctx, Core* core) : ExeUnit(ctx, core, "FPU") {}
    
void FpuUnit::tick() {
    if (Input.empty()) 
        return;
    auto trace = Input.front();
    switch (trace->fpu_type) {
    case FpuType::FNCP:
        Output.send(trace, 2);
        break;
    case FpuType::FMA:
        Output.send(trace, LATENCY_FMA+1);
        break;
    case FpuType::FDIV:
        Output.send(trace, LATENCY_FDIV+1);
        break;
    case FpuType::FSQRT:
        Output.send(trace, LATENCY_FSQRT+1);
        break;
    case FpuType::FCVT:
        Output.send(trace, LATENCY_FCVT+1);
        break;
    default:
        std::abort();
    }    
    DT(3, "pipeline-execute: op=" << trace->fpu_type << ", " << *trace);
    auto time = Input.pop();
    core_->perf_stats_.fpu_stalls += (SimPlatform::instance().cycles() - time);
}

///////////////////////////////////////////////////////////////////////////////

GpuUnit::GpuUnit(const SimContext& ctx, Core* core) 
    : ExeUnit(ctx, core, "GPU")   
    , tex_unit_(core->tex_unit_)
    , raster_srv_(core->raster_srv_)
    , rop_srv_(core->rop_srv_)
    , pending_rsps_{
        &core->tex_unit_->Output,
        &core->raster_srv_->Output,
        &core->rop_srv_->Output
    }
{}
    
void GpuUnit::tick() {
    // handle pending reponses
    for (auto pending_rsp : pending_rsps_) {
        if (pending_rsp->empty())
            continue;
        auto trace = pending_rsp->front();
        Output.send(trace, 1);
        pending_rsp->pop();
    }

    // check input queue
    if (Input.empty())
        return;

    auto trace = Input.front();

    switch  (trace->gpu_type) {
    case GpuType::TMC: {
        Output.send(trace, 1);
        auto trace_data = dynamic_cast<GPUTraceData*>(trace->data);
        core_->active_warps_.set(trace->wid, trace_data->active_warps.test(trace->wid));
    }   break;
    case GpuType::WSPAWN: {
        Output.send(trace, 1);
        auto trace_data = dynamic_cast<GPUTraceData*>(trace->data);
        core_->active_warps_ = trace_data->active_warps;
    }   break;
    case GpuType::SPLIT:
    case GpuType::JOIN:
        Output.send(trace, 1);
        break;
    case GpuType::BAR: {
        Output.send(trace, 1);
        auto trace_data = dynamic_cast<GPUTraceData*>(trace->data);
        if (trace_data->active_warps != 0) 
            core_->active_warps_ |= trace_data->active_warps;
        else
            core_->active_warps_.reset(trace->wid);
    }   break;
    case GpuType::TEX:
        tex_unit_->Input.send(trace, 1);
        break;
    case GpuType::RASTER:
        raster_srv_->Input.send(trace, 1);
        break;
    case GpuType::ROP:
        rop_srv_->Input.send(trace, 1);
        break;
    default:
        std::abort();
    }

    DT(3, "pipeline-execute: op=" << trace->gpu_type << ", " << *trace);
    if (trace->fetch_stall)  {
        core_->stalled_warps_.reset(trace->wid);
    }
    auto time = Input.pop();
    core_->perf_stats_.gpu_stalls += (SimPlatform::instance().cycles() - time);
}