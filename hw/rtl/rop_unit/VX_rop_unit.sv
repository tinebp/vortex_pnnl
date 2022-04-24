`include "VX_rop_define.vh"

module VX_rop_unit #(    
    parameter CLUSTER_ID = 0,    
    parameter NUM_SLICES = 1,
    parameter NUM_LANES  = NUM_SLICES
) (
    input wire clk,
    input wire reset,

    // PERF
`ifdef PERF_ENABLE
    VX_rop_perf_if.master rop_perf_if,
`endif

    // Memory interface
    VX_cache_req_if.master cache_req_if,
    VX_cache_rsp_if.slave  cache_rsp_if,

    // Inputs
    VX_rop_dcr_if.slave rop_dcr_if,
    VX_rop_req_if.slave rop_req_if
);
    rop_dcrs_t dcrs;
    assign dcrs = rop_dcr_if.data;

    VX_rop_slice #(
        .CLUSTER_ID (CLUSTER_ID),
        .NUM_LANES  (NUM_LANES)
    ) rop_slice (
        .clk            (clk),
        .reset          (reset),
    `ifdef PERF_ENABLE
        .rop_perf_if    (rop_perf_if),
    `endif
        .dcrs           (dcrs),

        .cache_req_if   (cache_req_if),
        .cache_rsp_if   (cache_rsp_if),

        .rop_req_if     (rop_req_if)
    );

`ifdef PERF_ENABLE
    reg [`PERF_CTR_BITS-1:0] perf_idle_cycles;
    reg [`PERF_CTR_BITS-1:0] perf_stall_cycles;

    wire perf_idle_cycle = ~rop_req_if.valid & rop_req_if.ready;
    wire perf_stall_cycle = rop_req_if.valid & ~rop_req_if.ready;

    always @(posedge clk) begin
        if (reset) begin
            perf_idle_cycles  <= 0;
            perf_stall_cycles <= 0;
        end else begin
            perf_idle_cycles  <= perf_idle_cycles + `PERF_CTR_BITS'(perf_idle_cycle);
            perf_stall_cycles <= perf_stall_cycles + `PERF_CTR_BITS'(perf_stall_cycle);
        end
    end

    assign rop_perf_if.idle_cycles = perf_idle_cycles;
    assign rop_perf_if.stall_cycles = perf_stall_cycles;
`endif

endmodule
