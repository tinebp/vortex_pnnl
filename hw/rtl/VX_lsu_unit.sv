`include "VX_define.vh"
`include "VX_gpu_types.vh"

`IGNORE_WARNINGS_BEGIN
import VX_gpu_types::*;
`IGNORE_WARNINGS_END

module VX_lsu_unit #(
    parameter CORE_ID = 0
) (    
    `SCOPE_IO_VX_lsu_unit

    input wire              clk,
    input wire              reset,

   // Dcache interface
    VX_cache_req_if.master  cache_req_if,
    VX_cache_rsp_if.slave   cache_rsp_if,

    // inputs
    VX_lsu_req_if.slave     lsu_req_if,

    // outputs
    VX_commit_if.master     ld_commit_if,
    VX_commit_if.master     st_commit_if
);
    localparam UUID_WIDTH = `UP(`UUID_BITS);
    localparam NW_WIDTH   = `UP(`NW_BITS);

    localparam MEM_ASHIFT = `CLOG2(`MEM_BLOCK_SIZE);    
    localparam MEM_ADDRW  = 32 - MEM_ASHIFT;
    localparam REQ_ASHIFT = `CLOG2(DCACHE_WORD_SIZE);

`ifdef SM_ENABLE
    localparam STACK_SIZE_W = `STACK_SIZE >> MEM_ASHIFT;
    localparam STACK_ADDR_W = `CLOG2(STACK_SIZE_W);
    localparam SMEM_LOCAL_SIZE_W = `SMEM_LOCAL_SIZE >> MEM_ASHIFT;

    localparam TOTAL_STACK_SIZE = `STACK_SIZE * `NUM_THREADS * `NUM_WARPS * `NUM_CORES;
    localparam STACK_START_W = MEM_ADDRW'(`STACK_BASE_ADDR >> MEM_ASHIFT);
    localparam STACK_END_W = MEM_ADDRW'((`STACK_BASE_ADDR - TOTAL_STACK_SIZE) >> MEM_ASHIFT);
`endif

    //                     uuid,        addr_type,                               wid,       PC,  tmask,         rd,        op_type,         align,                        is_dup
    localparam TAG_WIDTH = UUID_WIDTH + (`NUM_THREADS * `CACHE_ADDR_TYPE_BITS) + NW_WIDTH + 32 + `NUM_THREADS + `NR_BITS + `INST_LSU_BITS + (`NUM_THREADS * REQ_ASHIFT) + 1;

    `STATIC_ASSERT(0 == (`IO_BASE_ADDR % MEM_ASHIFT), ("invalid parameter"))
    `STATIC_ASSERT(0 == (`STACK_BASE_ADDR % MEM_ASHIFT), ("invalid parameter"))    
    `STATIC_ASSERT(`SMEM_LOCAL_SIZE == `MEM_BLOCK_SIZE * (`SMEM_LOCAL_SIZE / `MEM_BLOCK_SIZE), ("invalid parameter"))
    `STATIC_ASSERT(`STACK_SIZE == `MEM_BLOCK_SIZE * (`STACK_SIZE / `MEM_BLOCK_SIZE), ("invalid parameter"))
    `STATIC_ASSERT(`SMEM_LOCAL_SIZE >= `MEM_BLOCK_SIZE, ("invalid parameter"))

    wire [`NUM_THREADS-1:0][`CACHE_ADDR_TYPE_BITS-1:0] lsu_addr_type;

    // full address calculation

    wire [`NUM_THREADS-1:0][31:0] full_addr;    
    for (genvar i = 0; i < `NUM_THREADS; ++i) begin
        assign full_addr[i] = lsu_req_if.base_addr[i] + lsu_req_if.offset;
    end

    // detect duplicate addresses

    wire lsu_is_dup;
    if (`NUM_THREADS > 1) begin    
        wire [`NUM_THREADS-2:0] addr_matches;
        for (genvar i = 0; i < (`NUM_THREADS-1); ++i) begin
            assign addr_matches[i] = (lsu_req_if.base_addr[i+1] == lsu_req_if.base_addr[0]) || ~lsu_req_if.tmask[i+1];
        end
        assign lsu_is_dup = lsu_req_if.tmask[0] && (& addr_matches);
    end else begin
        assign lsu_is_dup = 0;
    end

    // detect address type

    for (genvar i = 0; i < `NUM_THREADS; ++i) begin
        wire [MEM_ADDRW-1:0] full_addr_b = full_addr[i][MEM_ASHIFT +: MEM_ADDRW];
        // is non-cacheable address
        wire is_addr_nc = (full_addr_b >= MEM_ADDRW'(`IO_BASE_ADDR >> MEM_ASHIFT));
    `ifdef SM_ENABLE
        // is stack address
        wire is_stack_addr = (full_addr_b >= STACK_END_W) && (full_addr_b < STACK_START_W);

        // check if address falls into shared memory region
        wire [STACK_ADDR_W-1:0] offset = full_addr_b[STACK_ADDR_W-1:0];
        wire is_addr_sm = is_stack_addr && (offset >= STACK_ADDR_W'(STACK_SIZE_W - SMEM_LOCAL_SIZE_W));

        assign lsu_addr_type[i] = {is_addr_nc, is_addr_sm};
    `else
        assign lsu_addr_type[i] = is_addr_nc;
    `endif
    end

    wire mem_req_empty;
    wire lsu_valid, lsu_ready;

    // fence: stall the pipeline until all pending requests are sent
    wire fence_wait = lsu_req_if.is_fence && ~mem_req_empty;
    
    assign lsu_valid = lsu_req_if.valid && ~fence_wait;
    assign lsu_req_if.ready = lsu_ready && ~fence_wait;

    // schedule memory request    

    wire                           mem_req_valid;
    wire [`NUM_THREADS-1:0]        mem_req_mask;
    wire                           mem_req_rw;  
    wire [`NUM_THREADS-1:0][29:0]  mem_req_addr;
    reg  [`NUM_THREADS-1:0][3:0]   mem_req_byteen;
    reg  [`NUM_THREADS-1:0][31:0]  mem_req_data;
    wire [TAG_WIDTH-1:0]           mem_req_tag;
    wire                           mem_req_ready;

    wire                           mem_rsp_valid;
    wire [`NUM_THREADS-1:0]        mem_rsp_mask;
    wire [`NUM_THREADS-1:0][31:0]  mem_rsp_data;
    wire [TAG_WIDTH-1:0]           mem_rsp_tag;
    wire                           mem_rsp_eop;
    wire                           mem_rsp_ready;

    assign mem_req_valid = lsu_valid;
    assign lsu_ready = mem_req_ready;

    for (genvar i = 0; i < `NUM_THREADS; ++i) begin
        assign mem_req_mask[i] = lsu_req_if.tmask[i] && (~lsu_is_dup || (i == 0));
    end

    assign mem_req_rw = ~lsu_req_if.wb;

    // address formatting

    wire [`NUM_THREADS-1:0][REQ_ASHIFT-1:0] req_align;

    for (genvar i = 0; i < `NUM_THREADS; ++i) begin  
        assign req_align[i]    = full_addr[i][1:0];
        assign mem_req_addr[i] = full_addr[i][31:2];
    end

    // data formatting
    
    for (genvar i = 0; i < `NUM_THREADS; ++i) begin
        wire [REQ_ASHIFT-1:0] req_align_X1 = {req_align[i][1], 1'b1};
        always @(*) begin
            mem_req_byteen[i] = {4{lsu_req_if.wb}};
            case (`INST_LSU_WSIZE(lsu_req_if.op_type))
                0: mem_req_byteen[i][req_align[i]] = 1;
                1: begin
                    mem_req_byteen[i][req_align[i]] = 1;
                    mem_req_byteen[i][req_align_X1] = 1;
                end
                default : mem_req_byteen[i] = {4{1'b1}};
            endcase
        end

        always @(*) begin
            mem_req_data[i] = lsu_req_if.store_data[i];
            case (req_align[i])
                1: mem_req_data[i][31:8]  = lsu_req_if.store_data[i][23:0];
                2: mem_req_data[i][31:16] = lsu_req_if.store_data[i][15:0];
                3: mem_req_data[i][31:24] = lsu_req_if.store_data[i][7:0];
                default:;
            endcase
        end
    end

    assign mem_req_tag = {lsu_req_if.uuid, lsu_addr_type, lsu_req_if.wid, lsu_req_if.tmask, lsu_req_if.PC, lsu_req_if.rd, lsu_req_if.op_type, req_align, lsu_is_dup};

     VX_cache_req_if #(
        .NUM_REQS  (DCACHE_NUM_REQS), 
        .WORD_SIZE (DCACHE_WORD_SIZE), 
        .TAG_WIDTH (UUID_WIDTH + (`NUM_THREADS * `CACHE_ADDR_TYPE_BITS) + LSUQ_TAG_BITS)
    ) cache_req_tmp_if();

    VX_cache_rsp_if #(
        .NUM_REQS  (DCACHE_NUM_REQS), 
        .WORD_SIZE (DCACHE_WORD_SIZE), 
        .TAG_WIDTH (UUID_WIDTH + (`NUM_THREADS * `CACHE_ADDR_TYPE_BITS) + LSUQ_TAG_BITS)
    ) cache_rsp_tmp_if();

    `RESET_RELAY (mem_scheduler_reset, reset);

    VX_mem_scheduler #(
        .INSTANCE_ID ($sformatf("core%0d-lsu-memsched", CORE_ID)),
        .NUM_REQS    (LSU_MEM_REQS), 
        .NUM_BANKS   (DCACHE_NUM_REQS),
        .ADDR_WIDTH  (DCACHE_ADDR_WIDTH),
        .DATA_WIDTH  (32),
        .QUEUE_SIZE  (`LSUQ_SIZE),
        .TAG_WIDTH   (TAG_WIDTH),
        .MEM_TAG_ID  (UUID_WIDTH + (`NUM_THREADS * `CACHE_ADDR_TYPE_BITS)),
        .UUID_WIDTH  (UUID_WIDTH),
        .RSP_PARTIAL (1),
        .MEM_OUT_REG (3)
    ) mem_scheduler (
        .clk            (clk),
        .reset          (mem_scheduler_reset),

        // Input request
        .req_valid      (mem_req_valid),
        .req_rw         (mem_req_rw),
        .req_mask       (mem_req_mask),
        .req_byteen     (mem_req_byteen),
        .req_addr       (mem_req_addr),
        .req_data       (mem_req_data),
        .req_tag        (mem_req_tag),
        .req_empty      (mem_req_empty),
        .req_ready      (mem_req_ready),
        `UNUSED_PIN     (write_notify),
        
        // Output response
        .rsp_valid      (mem_rsp_valid),
        .rsp_mask       (mem_rsp_mask),
        .rsp_data       (mem_rsp_data),
        .rsp_tag        (mem_rsp_tag),
        .rsp_eop        (mem_rsp_eop),
        .rsp_ready      (mem_rsp_ready),

        // Memory request
        .mem_req_valid  (cache_req_tmp_if.valid),
        .mem_req_rw     (cache_req_tmp_if.rw),
        .mem_req_byteen (cache_req_tmp_if.byteen),
        .mem_req_addr   (cache_req_tmp_if.addr),
        .mem_req_data   (cache_req_tmp_if.data),
        .mem_req_tag    (cache_req_tmp_if.tag),
        .mem_req_ready  (cache_req_tmp_if.ready),

        // Memory response
        .mem_rsp_valid  (cache_rsp_tmp_if.valid),
        .mem_rsp_data   (cache_rsp_tmp_if.data),
        .mem_rsp_tag    (cache_rsp_tmp_if.tag),
        .mem_rsp_ready  (cache_rsp_tmp_if.ready)
    );    

    wire mem_req_fire = mem_req_valid && mem_req_ready;
    wire mem_rsp_fire = mem_rsp_valid && mem_rsp_ready;
    `UNUSED_VAR (mem_req_fire)
    `UNUSED_VAR (mem_rsp_fire)

    // cache tag formatting:  <uuid, tag, type>

    `ASSIGN_VX_CACHE_REQ_IF_XTAG (cache_req_if, cache_req_tmp_if);
    `ASSIGN_VX_CACHE_RSP_IF_XTAG (cache_rsp_tmp_if, cache_rsp_if);
    
    for (genvar i = 0; i < DCACHE_NUM_REQS; ++i) begin
        wire [UUID_WIDTH-1:0]                              cache_req_uuid, cache_rsp_uuid;
        wire [`NUM_THREADS-1:0][`CACHE_ADDR_TYPE_BITS-1:0] cache_req_type, cache_rsp_type;        
        wire [`CLOG2(`LSUQ_SIZE)-1:0]                      cache_req_tag,  cache_rsp_tag;

        if (DCACHE_NUM_BATCHES > 1) begin

            wire [DCACHE_NUM_BATCHES-1:0][`CACHE_ADDR_TYPE_BITS-1:0] cache_req_type_b, cache_rsp_type_b;            
            wire [`CACHE_ADDR_TYPE_BITS-1:0] cache_req_type_bi, cache_rsp_type_bi;
            wire [DCACHE_BATCH_SEL_BITS-1:0] cache_req_bid, cache_rsp_bid;

            assign {cache_req_uuid, cache_req_type, cache_req_bid, cache_req_tag} = cache_req_tmp_if.tag[i];
            assign cache_req_type_bi = cache_req_type_b[cache_req_bid];
            assign cache_req_if.tag[i] = {cache_req_uuid, cache_req_bid, cache_req_tag, cache_req_type_bi};

            assign {cache_rsp_uuid, cache_rsp_bid, cache_rsp_tag, cache_rsp_type_bi} = cache_rsp_if.tag[i];
            assign cache_rsp_type_b = {DCACHE_NUM_BATCHES{cache_rsp_type_bi}};
            assign cache_rsp_tmp_if.tag[i] = {cache_rsp_uuid, cache_rsp_type, cache_rsp_bid, cache_rsp_tag};

            for (genvar j = 0; j < DCACHE_NUM_BATCHES; ++j) begin
                localparam k = j * DCACHE_NUM_REQS + i;                
                if (k < `NUM_THREADS) begin
                    assign cache_req_type_b[j] = cache_req_type[k];
                    assign cache_rsp_type[k] = cache_rsp_type_b[j];
                end else begin
                    assign cache_req_type_b[j] = '0;
                    `UNUSED_VAR (cache_rsp_type_b[j])
                end
            end

        end else begin
            
            assign {cache_req_uuid, cache_req_type, cache_req_tag} = cache_req_tmp_if.tag[i];
            assign cache_req_if.tag[i] = {cache_req_uuid, cache_req_tag, cache_req_type[i]};

            assign {cache_rsp_uuid, cache_rsp_tag, cache_rsp_type[i]} = cache_rsp_if.tag[i];
            assign cache_rsp_tmp_if.tag[i] = {cache_rsp_uuid, cache_rsp_type, cache_rsp_tag};        

            for (genvar j = 0; j < DCACHE_NUM_REQS; ++j) begin
                if (i != j) begin
                    `UNUSED_VAR (cache_req_type[j])
                    assign cache_rsp_type[j] = '0;
                end
            end
        end
    end
    
    wire [UUID_WIDTH-1:0] rsp_uuid;
    wire [`NUM_THREADS-1:0][`CACHE_ADDR_TYPE_BITS-1:0] rsp_addr_type;
    wire [NW_WIDTH-1:0] rsp_wid;
    wire [`NUM_THREADS-1:0] rsp_tmask_uq;
    wire [31:0] rsp_pc;
    wire [`NR_BITS-1:0] rsp_rd;
    wire [`INST_LSU_BITS-1:0] rsp_op_type;
    wire [`NUM_THREADS-1:0][REQ_ASHIFT-1:0] rsp_align;
    wire rsp_is_dup;

    assign {rsp_uuid, rsp_addr_type, rsp_wid, rsp_tmask_uq, rsp_pc, rsp_rd, rsp_op_type, rsp_align, rsp_is_dup} = mem_rsp_tag;
    `UNUSED_VAR (rsp_addr_type)
    `UNUSED_VAR (rsp_op_type)
    
    // send store commit

    assign st_commit_if.valid = mem_req_fire && mem_req_rw;
    assign st_commit_if.uuid  = lsu_req_if.uuid;
    assign st_commit_if.wid   = lsu_req_if.wid;
    assign st_commit_if.tmask = lsu_req_if.tmask;
    assign st_commit_if.PC    = lsu_req_if.PC;
    assign st_commit_if.rd    = '0;
    assign st_commit_if.wb    = 0;
    assign st_commit_if.eop   = 1;
    assign st_commit_if.data  = '0;
    `UNUSED_VAR (st_commit_if.ready) // stall-free

    // load response formatting

    reg [`NUM_THREADS-1:0][31:0] rsp_data;
    wire [`NUM_THREADS-1:0] rsp_tmask;

    for (genvar i = 0; i < `NUM_THREADS; ++i) begin
        wire [31:0] rsp_data32 = (i == 0 || rsp_is_dup) ? mem_rsp_data[0] : mem_rsp_data[i];
        wire [15:0] rsp_data16 = rsp_align[i][1] ? rsp_data32[31:16] : rsp_data32[15:0];
        wire [7:0]  rsp_data8  = rsp_align[i][0] ? rsp_data16[15:8] : rsp_data16[7:0];

        always @(*) begin
            case (`INST_LSU_FMT(rsp_op_type))
            `INST_FMT_B:  rsp_data[i] = 32'(signed'(rsp_data8));
            `INST_FMT_H:  rsp_data[i] = 32'(signed'(rsp_data16));
            `INST_FMT_BU: rsp_data[i] = 32'(unsigned'(rsp_data8));
            `INST_FMT_HU: rsp_data[i] = 32'(unsigned'(rsp_data16));
            `INST_FMT_W:  rsp_data[i] = rsp_data32;
            default:      rsp_data[i] = 'x;
            endcase
        end        
    end   

    assign rsp_tmask = rsp_is_dup ? rsp_tmask_uq : mem_rsp_mask;

    // send load commit

    VX_skid_buffer #(
        .DATAW (UUID_WIDTH + NW_WIDTH + `NUM_THREADS + 32 + `NR_BITS + 1 + (`NUM_THREADS * 32) + 1)
    ) rsp_sbuf (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (mem_rsp_valid),
        .ready_in  (mem_rsp_ready),
        .data_in   ({rsp_uuid,          rsp_wid,          rsp_tmask,          rsp_pc,          rsp_rd,          1'b1,            rsp_data,          mem_rsp_eop}),
        .data_out  ({ld_commit_if.uuid, ld_commit_if.wid, ld_commit_if.tmask, ld_commit_if.PC, ld_commit_if.rd, ld_commit_if.wb, ld_commit_if.data, ld_commit_if.eop}),
        .valid_out (ld_commit_if.valid),
        .ready_out (ld_commit_if.ready)
    );

`ifdef CHIPSCOPE_LSU
    wire [31:0] full_addr_0 = full_addr[0];
    wire [31:0] mem_req_data_0 = mem_req_data[0];
    wire [31:0] rsp_data_0 = rsp_data[0];
    ila_lsu ila_lsu_inst (
        .clk    (clk),
        .probe0 ({mem_req_data_0, lsu_req_if.uuid, lsu_req_if.wid, lsu_req_if.PC, mem_req_mask, full_addr_0, mem_req_byteen, mem_req_rw, mem_req_ready, mem_req_valid}),
        .probe1 ({rsp_data_0, rsp_uuid, mem_rsp_eop, rsp_pc, rsp_rd, rsp_tmask, rsp_wid, mem_rsp_ready, mem_rsp_valid}),
        .probe2 ({cache_req_if.data, cache_req_if.tag, cache_req_if.byteen, cache_req_if.addr, cache_req_if.rw, cache_req_if.ready, cache_req_if.valid}),
        .probe3 ({cache_rsp_if.data, cache_rsp_if.tag, cache_rsp_if.ready, cache_rsp_if.valid})
    );
`endif

    // scope registration
    `SCOPE_ASSIGN (dcache_req_fire,  mem_req_fire);
    `SCOPE_ASSIGN (dcache_req_uuid,  lsu_req_if.uuid);
    `SCOPE_ASSIGN (dcache_req_addr,  full_addr);
    `SCOPE_ASSIGN (dcache_req_rw,    mem_req_rw);
    `SCOPE_ASSIGN (dcache_req_byteen, mem_req_byteen);
    `SCOPE_ASSIGN (dcache_req_data,  mem_req_data);
    `SCOPE_ASSIGN (dcache_rsp_fire,  mem_rsp_fire);
    `SCOPE_ASSIGN (dcache_rsp_uuid,  rsp_uuid);
    `SCOPE_ASSIGN (dcache_rsp_data,  rsp_data);
    
`ifdef DBG_TRACE_CORE_DCACHE
    always @(posedge clk) begin    
        if (lsu_req_if.valid && fence_wait) begin
            `TRACE(1, ("%d: *** D$%0d fence wait\n", $time, CORE_ID));
        end
        if (mem_req_fire) begin
            if (mem_req_rw) begin
                `TRACE(1, ("%d: D$%0d Wr Req: wid=%0d, PC=0x%0h, tmask=%b, addr=", $time, CORE_ID, lsu_req_if.wid, lsu_req_if.PC, mem_req_mask));
                `TRACE_ARRAY1D(1, full_addr, `NUM_THREADS);
                `TRACE(1, (", tag=0x%0h, byteen=0x%0h, type=", mem_req_tag, mem_req_byteen));
                `TRACE_ARRAY1D(1, lsu_addr_type, `NUM_THREADS);
                `TRACE(1, (", data="));
                `TRACE_ARRAY1D(1, mem_req_data, `NUM_THREADS);
                `TRACE(1, (", is_dup=%b (#%0d)\n", lsu_is_dup, lsu_req_if.uuid));
            end else begin
                `TRACE(1, ("%d: D$%0d Rd Req: wid=%0d, PC=0x%0h, tmask=%b, addr=", $time, CORE_ID, lsu_req_if.wid, lsu_req_if.PC, mem_req_mask));
                `TRACE_ARRAY1D(1, full_addr, `NUM_THREADS);
                `TRACE(1, (", tag=0x%0h, byteen=0x%0h, type=", mem_req_tag, mem_req_byteen));
                `TRACE_ARRAY1D(1, lsu_addr_type, `NUM_THREADS);
                `TRACE(1, (", rd=%0d, is_dup=%b (#%0d)\n", lsu_req_if.rd, lsu_is_dup, lsu_req_if.uuid));
            end
        end
        if (mem_rsp_fire) begin
            `TRACE(1, ("%d: D$%0d Rsp: wid=%0d, PC=0x%0h, tmask=%b, tag=0x%0h, rd=%0d, data=",
                $time, CORE_ID, rsp_wid, rsp_pc, mem_rsp_mask, mem_rsp_tag, rsp_rd));
            `TRACE_ARRAY1D(1, mem_rsp_data, `NUM_THREADS);
            `TRACE(1, (", is_dup=%b (#%0d)\n", rsp_is_dup, rsp_uuid));
        end
    end
`endif
    
endmodule
