`include "VX_rop_define.vh"

// Module for handling memory requests
module VX_rop_mem #(
    parameter CLUSTER_ID = 0,
    parameter NUM_LANES  = 4,
    parameter TAG_WIDTH  = 1
) (
    input wire clk,
    input wire reset,

    // PERF
`ifdef PERF_ENABLE
    VX_rop_perf_if.master rop_perf_if,
`endif

    // Device configuration
    input rop_dcrs_t dcrs,

    // Memory interface
    VX_cache_req_if.master cache_req_if,
    VX_cache_rsp_if.slave  cache_rsp_if,

    // Request interface
    input wire                                      req_valid,
    input wire [NUM_LANES-1:0]                      req_tmask,
    input wire                                      req_rw,
    input wire [NUM_LANES-1:0][`ROP_DIM_BITS-1:0]   req_pos_x,
    input wire [NUM_LANES-1:0][`ROP_DIM_BITS-1:0]   req_pos_y,
    input rgba_t [NUM_LANES-1:0]                    req_color, 
    input wire [NUM_LANES-1:0][`ROP_DEPTH_BITS-1:0] req_depth,
    input wire [NUM_LANES-1:0][`ROP_STENCIL_BITS-1:0] req_stencil,
    input wire [TAG_WIDTH-1:0]                      req_tag,
    output wire                                     req_ready,

    // Response interface
    output wire                         rsp_valid,
    output wire [NUM_LANES-1:0]         rsp_tmask,
    output rgba_t [NUM_LANES-1:0]       rsp_color, 
    output wire [NUM_LANES-1:0][`ROP_DEPTH_BITS-1:0] rsp_depth,
    output wire [NUM_LANES-1:0][`ROP_STENCIL_BITS-1:0] rsp_stencil,
    output wire [TAG_WIDTH-1:0]         rsp_tag,
    input wire                          rsp_ready
);
    // TODO
    `UNUSED_VAR (clk)
    `UNUSED_VAR (reset)

    // TODO
    `UNUSED_VAR (dcrs)

    // TODO
    `UNUSED_VAR (req_valid)
    `UNUSED_VAR (req_tmask)
    `UNUSED_VAR (req_rw)
    `UNUSED_VAR (req_pos_x)
    `UNUSED_VAR (req_pos_y)    
    `UNUSED_VAR (req_color)
    `UNUSED_VAR (req_depth)
    `UNUSED_VAR (req_stencil)
    `UNUSED_VAR (req_tag)
    assign req_ready = 0;

   // TODO
    assign rsp_valid = 0;
    assign rsp_tmask = 0;
    assign rsp_color = 0;
    assign rsp_depth = 0;
    assign rsp_stencil = 0;     
    assign rsp_tag = 0;
    `UNUSED_VAR (rsp_ready)

    // TODO
    assign cache_req_if.valid = 0;
    assign cache_req_if.rw = 0;
    assign cache_req_if.byteen = 0;
    assign cache_req_if.addr = 0;
    assign cache_req_if.data = 0;     
    assign cache_req_if.tag = 0;
    `UNUSED_VAR (cache_req_if.ready)

    // TODO
    `UNUSED_VAR (cache_rsp_if.valid)
    `UNUSED_VAR (cache_rsp_if.tmask)
    `UNUSED_VAR (cache_rsp_if.data)        
    `UNUSED_VAR (cache_rsp_if.tag)
    assign cache_rsp_if.ready = 0;
    
`ifdef PERF_ENABLE
    // TODO
    assign rop_perf_if.mem_reads = 0;
    assign rop_perf_if.mem_writes = 0;
    assign rop_perf_if.mem_latency = 0;
`endif

    /*
    VX_mem_streamer #(
        .NUM_REQS (NUM_LANES),
        .ADDRW (32),
        .DATAW (32),
        .TAGW (32),
        .WORD_SIZE (4),
        .QUEUE_SIZE (16),
        .PARTIAL_RESPONSE (1)
    ) mem_streamer (
        .clk            (clk),
        .reset          (reset),

        .req_valid      (req_valid),
        .req_rw         (req_rw),
        .req_mask       (req_mask),
        .req_byteen     (req_byteen),
        .req_addr       (req_addr),
        .req_data       (req_data),
        .req_tag        (req_tag),
        .req_ready      (req_ready),

        .rsp_valid      (rsp_valid),
        .rsp_mask       (rsp_mask),
        .rsp_data       (rsp_data),
        .rsp_tag        (rsp_tag),
        .rsp_ready      (rsp_ready),

        .mem_req_valid  (cache_req_if.valid),
        .mem_req_rw     (cache_req_if.rw),
        .mem_req_byteen (cache_req_if.byteen),
        .mem_req_addr   (cache_req_if.addr),
        .mem_req_data   (cache_req_if.data),
        .mem_req_tag    (cache_req_if.tag),
        .mem_req_ready  (cache_req_if.ready),

        .mem_rsp_valid  (cache_rsp_if.valid),
        .mem_rsp_mask   (cache_rsp_if.mask),
        .mem_rsp_data   (cache_rsp_if.data),
        .mem_rsp_tag    (cache_rsp_if.tag),
        .mem_rsp_ready  (cache_rsp_if.ready)
    );*/
    
endmodule