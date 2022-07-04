`include "VX_define.vh"
`include "VX_gpu_types.vh"
`include "VX_cache_types.vh"

`IGNORE_WARNINGS_BEGIN
import VX_cache_types::*;
import VX_gpu_types::*;
`IGNORE_WARNINGS_END

module VX_socket #( 
    parameter SOCKET_ID = 0
) (        
    `SCOPE_IO_VX_socket
    
    // Clock
    input wire              clk,
    input wire              reset,

`ifdef PERF_ENABLE
    VX_perf_memsys_if.slave perf_memsys_if,
`endif

    input base_dcrs_t       base_dcrs,

    VX_cache_req_if.master  dcache_req_if,
    VX_cache_rsp_if.slave   dcache_rsp_if,

    VX_cache_req_if.master  icache_req_if,
    VX_cache_rsp_if.slave   icache_rsp_if,    

`ifdef EXT_F_ENABLE
    VX_fpu_req_if.master    fpu_req_if,
    VX_fpu_rsp_if.slave     fpu_rsp_if,
`endif

`ifdef EXT_TEX_ENABLE
`ifdef PERF_ENABLE
    VX_tex_perf_if.slave    perf_tex_if,
    VX_perf_cache_if.slave  perf_tcache_if,
`endif
    VX_tex_req_if.master    tex_req_if,
    VX_tex_rsp_if.slave     tex_rsp_if,
`endif

`ifdef EXT_RASTER_ENABLE
`ifdef PERF_ENABLE
    VX_raster_perf_if.slave perf_raster_if,
    VX_perf_cache_if.slave  perf_rcache_if,
`endif
    VX_raster_req_if.slave  raster_req_if,
`endif

`ifdef EXT_ROP_ENABLE
`ifdef PERF_ENABLE
    VX_rop_perf_if.slave    perf_rop_if,
    VX_perf_cache_if.slave  perf_ocache_if,
`endif
    VX_rop_req_if.master    rop_req_if,
`endif

    // simulation helper signals
    output wire             sim_ebreak,
    output wire [`NUM_REGS-1:0][31:0] sim_wb_value,

    // Status
    output wire             busy
);

`ifdef EXT_RASTER_ENABLE

    VX_raster_req_if #(
        .NUM_LANES (`NUM_THREADS)
    ) per_core_raster_req_if[`SOCKET_SIZE](), raster_req_tmp_if[1]();

    VX_raster_arb #(
        .NUM_INPUTS  (1),
        .NUM_LANES   (`NUM_THREADS),
        .NUM_OUTPUTS (`SOCKET_SIZE),
        .ARBITER     ("R"),
        .BUFFERED    ((`SOCKET_SIZE > 1) ? 2 : 0)
    ) raster_arb (
        .clk        (clk),
        .reset      (reset),
        .req_in_if  (raster_req_tmp_if),
        .req_out_if (per_core_raster_req_if)
    );

    `ASSIGN_VX_RASTER_REQ_IF (raster_req_tmp_if[0], raster_req_if);

`endif

`ifdef EXT_ROP_ENABLE

    VX_rop_req_if #(
        .NUM_LANES (`NUM_THREADS)
    ) per_core_rop_req_if[`SOCKET_SIZE](), rop_req_tmp_if[1]();

    VX_rop_arb #(
        .NUM_INPUTS  (`SOCKET_SIZE),
        .NUM_LANES   (`NUM_THREADS),
        .NUM_OUTPUTS (1),
        .ARBITER     ("R"),
        .BUFFERED    ((`SOCKET_SIZE > 1) ? 2 : 0)
    ) rop_arb (
        .clk        (clk),
        .reset      (reset),
        .req_in_if  (per_core_rop_req_if),
        .req_out_if (rop_req_tmp_if)
    );

    `ASSIGN_VX_ROP_REQ_IF (rop_req_if, rop_req_tmp_if[0]);

`endif

`ifdef EXT_TEX_ENABLE

    VX_tex_req_if #(
        .NUM_LANES (`NUM_THREADS),
        .TAG_WIDTH (`TEX_REQ_TAG_WIDTH)
    ) per_core_tex_req_if[`SOCKET_SIZE]();

    VX_tex_rsp_if #(
        .NUM_LANES (`NUM_THREADS),
        .TAG_WIDTH (`TEX_REQ_TAG_WIDTH)
    ) per_core_tex_rsp_if[`SOCKET_SIZE]();

    VX_tex_req_if #(
        .NUM_LANES (`NUM_THREADS),
        .TAG_WIDTH (`TEX_REQ_ARB1_TAG_WIDTH)
    ) tex_req_tmp_if[1]();

    VX_tex_rsp_if #(
        .NUM_LANES (`NUM_THREADS),
        .TAG_WIDTH (`TEX_REQ_ARB1_TAG_WIDTH)
    ) tex_rsp_tmp_if[1]();

    VX_tex_arb #(
        .NUM_INPUTS   (`SOCKET_SIZE),
        .NUM_LANES    (`NUM_THREADS),
        .NUM_OUTPUTS  (1),
        .TAG_WIDTH    (`TEX_REQ_TAG_WIDTH),
        .ARBITER      ("R"),
        .BUFFERED_REQ ((`SOCKET_SIZE > 1) ? 2 : 0)
    ) tex_arb (
        .clk        (clk),
        .reset      (reset),
        .req_in_if  (per_core_tex_req_if),
        .rsp_in_if  (per_core_tex_rsp_if),
        .req_out_if (tex_req_tmp_if),
        .rsp_out_if (tex_rsp_tmp_if)
    );

    `ASSIGN_VX_TEX_REQ_IF (tex_req_if, tex_req_tmp_if[0]);
    `ASSIGN_VX_TEX_RSP_IF (tex_rsp_tmp_if[0], tex_rsp_if);
            
`endif

`ifdef EXT_F_ENABLE

    VX_fpu_req_if #(
        .NUM_LANES (`NUM_THREADS),
        .TAG_WIDTH (`FPU_REQ_TAG_WIDTH)
    ) per_core_fpu_req_if[`SOCKET_SIZE]();

    VX_fpu_rsp_if #(
        .NUM_LANES (`NUM_THREADS),
        .TAG_WIDTH (`FPU_REQ_TAG_WIDTH)
    ) per_core_fpu_rsp_if[`SOCKET_SIZE]();

    VX_fpu_req_if #(
        .NUM_LANES (`NUM_THREADS),
        .TAG_WIDTH (`FPU_REQ_ARB1_TAG_WIDTH)
    ) fpu_req_tmp_if[1]();

    VX_fpu_rsp_if #(
        .NUM_LANES (`NUM_THREADS),
        .TAG_WIDTH (`FPU_REQ_ARB1_TAG_WIDTH)
    ) fpu_rsp_tmp_if[1]();

    VX_fpu_arb #(
        .NUM_INPUTS   (`SOCKET_SIZE),
        .NUM_LANES    (`NUM_THREADS),
        .NUM_OUTPUTS  (1),
        .TAG_WIDTH    (`FPU_REQ_TAG_WIDTH),
        .ARBITER      ("R"),
        .BUFFERED_REQ ((`SOCKET_SIZE > 1) ? 2 : 0)
    ) fpu_arb (
        .clk        (clk),
        .reset      (reset),
        .req_in_if  (per_core_fpu_req_if),
        .rsp_in_if  (per_core_fpu_rsp_if),
        .req_out_if (fpu_req_tmp_if),
        .rsp_out_if (fpu_rsp_tmp_if)
    );

    `ASSIGN_VX_FPU_REQ_IF (fpu_req_if, fpu_req_tmp_if[0]);
    `ASSIGN_VX_FPU_RSP_IF (fpu_rsp_tmp_if[0], fpu_rsp_if);

`endif

    ///////////////////////////////////////////////////////////////////////////

    VX_cache_req_if #(
        .NUM_REQS  (DCACHE_NUM_REQS), 
        .WORD_SIZE (DCACHE_WORD_SIZE), 
        .TAG_WIDTH (DCACHE_TAG_WIDTH)
    ) per_core_dcache_req_if[`SOCKET_SIZE]();

    VX_cache_rsp_if #(
        .NUM_REQS  (DCACHE_NUM_REQS), 
        .WORD_SIZE (DCACHE_WORD_SIZE), 
        .TAG_WIDTH (DCACHE_TAG_WIDTH)
    ) per_core_dcache_rsp_if[`SOCKET_SIZE]();

    VX_cache_req_if #(
        .NUM_REQS  (DCACHE_NUM_REQS), 
        .WORD_SIZE (DCACHE_WORD_SIZE),
        .TAG_WIDTH (DCACHE_ARB_TAG_WIDTH)
    ) dcache_req_tmp_if[1]();

    VX_cache_rsp_if #(
        .NUM_REQS  (DCACHE_NUM_REQS), 
        .WORD_SIZE (DCACHE_WORD_SIZE), 
        .TAG_WIDTH (DCACHE_ARB_TAG_WIDTH)
    ) dcache_rsp_tmp_if[1]();

    VX_cache_arb #(
        .NUM_INPUTS   (`SOCKET_SIZE),
        .NUM_OUTPUTS  (1),
        .NUM_LANES    (DCACHE_NUM_REQS),
        .DATA_SIZE    (DCACHE_WORD_SIZE),
        .TAG_WIDTH    (DCACHE_TAG_WIDTH),
        .TAG_SEL_IDX  (`CACHE_ADDR_TYPE_BITS),
        .ARBITER      ("R"),
        .BUFFERED_REQ ((`SOCKET_SIZE > 1) ? 2 : 0),
        .BUFFERED_RSP ((`SOCKET_SIZE > 1) ? 2 : 0)
    ) dcache_arb (
        .clk        (clk),
        .reset      (reset),
        .req_in_if  (per_core_dcache_req_if),
        .rsp_in_if  (per_core_dcache_rsp_if),
        .req_out_if (dcache_req_tmp_if),
        .rsp_out_if (dcache_rsp_tmp_if)
    );

    `ASSIGN_VX_CACHE_REQ_IF (dcache_req_if, dcache_req_tmp_if[0]);
    `ASSIGN_VX_CACHE_RSP_IF (dcache_rsp_tmp_if[0], dcache_rsp_if);

    ///////////////////////////////////////////////////////////////////////////
    
    VX_cache_req_if #(
        .NUM_REQS  (ICACHE_NUM_REQS), 
        .WORD_SIZE (ICACHE_WORD_SIZE), 
        .TAG_WIDTH (ICACHE_TAG_WIDTH)
    ) per_core_icache_req_if[`SOCKET_SIZE]();

    VX_cache_rsp_if #(
        .NUM_REQS  (ICACHE_NUM_REQS), 
        .WORD_SIZE (ICACHE_WORD_SIZE), 
        .TAG_WIDTH (ICACHE_TAG_WIDTH)
    ) per_core_icache_rsp_if[`SOCKET_SIZE]();

    VX_cache_req_if #(
        .NUM_REQS  (ICACHE_NUM_REQS), 
        .WORD_SIZE (ICACHE_WORD_SIZE),
        .TAG_WIDTH (ICACHE_ARB_TAG_WIDTH)
    ) icache_req_tmp_if[1]();

    VX_cache_rsp_if #(
        .NUM_REQS  (ICACHE_NUM_REQS), 
        .WORD_SIZE (ICACHE_WORD_SIZE), 
        .TAG_WIDTH (ICACHE_ARB_TAG_WIDTH)
    ) icache_rsp_tmp_if[1]();

    VX_cache_arb #(
        .NUM_INPUTS   (`SOCKET_SIZE),
        .NUM_OUTPUTS  (1),
        .NUM_LANES    (ICACHE_NUM_REQS),
        .DATA_SIZE    (ICACHE_WORD_SIZE),
        .TAG_WIDTH    (ICACHE_TAG_WIDTH),
        .TAG_SEL_IDX  (0),
        .ARBITER      ("R"),
        .BUFFERED_REQ ((`SOCKET_SIZE > 1) ? 2 : 0),
        .BUFFERED_RSP ((`SOCKET_SIZE > 1) ? 2 : 0)
    ) icache_arb (
        .clk        (clk),
        .reset      (reset),
        .req_in_if  (per_core_icache_req_if),
        .rsp_in_if  (per_core_icache_rsp_if),
        .req_out_if (icache_req_tmp_if),
        .rsp_out_if (icache_rsp_tmp_if)
    );

    `ASSIGN_VX_CACHE_REQ_IF (icache_req_if, icache_req_tmp_if[0]);
    `ASSIGN_VX_CACHE_RSP_IF (icache_rsp_tmp_if[0], icache_rsp_if);

    ///////////////////////////////////////////////////////////////////////////

    wire [`SOCKET_SIZE-1:0] per_core_sim_ebreak;
    wire [`SOCKET_SIZE-1:0][`NUM_REGS-1:0][31:0] per_core_sim_wb_value;
    assign sim_ebreak = per_core_sim_ebreak[0];
    assign sim_wb_value = per_core_sim_wb_value[0];
    `UNUSED_VAR (per_core_sim_ebreak)
    `UNUSED_VAR (per_core_sim_wb_value)

    wire [`SOCKET_SIZE-1:0] per_core_busy;

    // Generate all cores
    for (genvar i = 0; i < `SOCKET_SIZE; ++i) begin

        `RESET_RELAY_EX (core_reset, reset, (`SOCKET_SIZE > 1));        

        `BUFFER_EX (core_base_dcrs, base_dcrs, (`SOCKET_SIZE > 1));

        VX_core #(
            .CORE_ID ((SOCKET_ID * `SOCKET_SIZE) + i)
        ) core (
            `SCOPE_BIND_VX_socket_core(i)

            .clk            (clk),
            .reset          (core_reset),

        `ifdef PERF_ENABLE
            .perf_memsys_if (perf_memsys_if),
        `endif
            
            .base_dcrs      (core_base_dcrs),
            .dcache_req_if  (per_core_dcache_req_if[i]),
            .dcache_rsp_if  (per_core_dcache_rsp_if[i]),

            .icache_req_if  (per_core_icache_req_if[i]),
            .icache_rsp_if  (per_core_icache_rsp_if[i]),

        `ifdef EXT_F_ENABLE
            .fpu_req_if     (per_core_fpu_req_if[i]),
            .fpu_rsp_if     (per_core_fpu_rsp_if[i]),
        `endif

        `ifdef EXT_TEX_ENABLE
        `ifdef PERF_ENABLE
            .perf_tex_if    (perf_tex_if),
            .perf_tcache_if (perf_tcache_if),
        `endif
            .tex_req_if     (per_core_tex_req_if[i]),
            .tex_rsp_if     (per_core_tex_rsp_if[i]),
        `endif

        `ifdef EXT_RASTER_ENABLE
        `ifdef PERF_ENABLE
            .perf_raster_if (perf_raster_if),
            .perf_rcache_if (perf_rcache_if),
        `endif
            .raster_req_if  (per_core_raster_req_if[i]),
        `endif
        
        `ifdef EXT_ROP_ENABLE
        `ifdef PERF_ENABLE
            .perf_rop_if    (perf_rop_if),
            .perf_ocache_if (perf_ocache_if),
        `endif
            .rop_req_if     (per_core_rop_req_if[i]),
        `endif

            .sim_ebreak     (per_core_sim_ebreak[i]),
            .sim_wb_value   (per_core_sim_wb_value[i]),
            .busy           (per_core_busy[i])
        );
    end
    
    assign busy = (| per_core_busy);
    
endmodule
