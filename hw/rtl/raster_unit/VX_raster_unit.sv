`include "VX_raster_define.vh"

module VX_raster_unit #(
    parameter `STRING_TYPE INSTANCE_ID = "",
    parameter INSTANCE_IDX    = 0,
    parameter NUM_INSTANCES   = 1, 
    parameter NUM_PES         = 1,  // number of processing elements
    parameter TILE_LOGSIZE    = 5,  // tile log size
    parameter BLOCK_LOGSIZE   = 2,  // block log size
    parameter MEM_FIFO_DEPTH  = 4,  // memory queue size
    parameter QUAD_FIFO_DEPTH = 4,  // quad queue size
    parameter OUTPUT_QUADS    = 4   // number of output quads    
) (
    input wire clk,
    input wire reset,

    // PERF
`ifdef PERF_ENABLE
    VX_raster_perf_if.master perf_raster_if,
`endif

    // Memory interface
    VX_cache_req_if.master  cache_req_if,
    VX_cache_rsp_if.slave   cache_rsp_if,

    // Inputs
    VX_dcr_write_if.slave   dcr_write_if,

    // Outputs
    VX_raster_req_if.master raster_req_if
);
    localparam EDGE_FUNC_LATENCY = `LATENCY_IMUL;

    // A primitive data contains (x_loc, y_loc, pid, edges, extents)
    localparam PRIM_DATA_WIDTH = 2 * `RASTER_DIM_BITS + `RASTER_PID_BITS + 9 * `RASTER_DATA_BITS + 3 * `RASTER_DATA_BITS;

    `STATIC_ASSERT(TILE_LOGSIZE > BLOCK_LOGSIZE, ("invalid parameter"))

    // DCRs

    raster_dcrs_t raster_dcrs;

    VX_raster_dcr #(
        .INSTANCE_ID  (INSTANCE_ID),
        .INSTANCE_IDX (INSTANCE_IDX),
        .NUM_INSTANCES(NUM_INSTANCES)
    ) raster_dcr (
        .clk        (clk),
        .reset      (reset),
        .dcr_write_if(dcr_write_if),
        .raster_dcrs(raster_dcrs)
    );

    ///////////////////////////////////////////////////////////////////////////

    // Output from the request
    wire [`RASTER_DIM_BITS-1:0] mem_x_loc;
    wire [`RASTER_DIM_BITS-1:0] mem_y_loc;
    wire [2:0][2:0][`RASTER_DATA_BITS-1:0] mem_edges;
    wire [`RASTER_PID_BITS-1:0] mem_pid;
    
    // Memory unit status
    reg mem_unit_running;
    wire mem_unit_busy;
    wire mem_unit_valid;    
    wire mem_unit_ready;

    `RESET_RELAY (mem_reset, reset);

    // Generate start pulse
    always @(posedge clk) begin
        mem_unit_running <= ~mem_reset;
    end
    wire mem_unit_start = ~mem_reset && ~mem_unit_running;

    // Memory unit
    VX_raster_mem #(
        .INSTANCE_ID  (INSTANCE_ID),
        .TILE_LOGSIZE (TILE_LOGSIZE),
        .QUEUE_SIZE   (MEM_FIFO_DEPTH)
    ) raster_mem (
        .clk          (clk),
        .reset        (mem_reset),

        .start        (mem_unit_start),        
        .busy         (mem_unit_busy),

        .dcrs         (raster_dcrs),

        .cache_req_if (cache_req_if),
        .cache_rsp_if (cache_rsp_if), 

        .valid_out    (mem_unit_valid),
        .x_loc_out    (mem_x_loc),
        .y_loc_out    (mem_y_loc),
        .edges_out    (mem_edges),
        .pid_out      (mem_pid),
        .ready_out    (mem_unit_ready)
    );

    // Edge function and extents calculation

    wire [2:0][`RASTER_DATA_BITS-1:0] edge_eval;
    wire [2:0][`RASTER_DATA_BITS-1:0] mem_extents;
    wire edge_func_stall;

    VX_raster_extents #(
        .TILE_LOGSIZE (TILE_LOGSIZE)
    ) raster_extents (
        .edges   (mem_edges),
        .extents (mem_extents)
    );

    VX_raster_edge #(
        .LATENCY (EDGE_FUNC_LATENCY)
    ) raster_edge (
        .clk    (clk),
        .reset  (reset),
        .enable (~edge_func_stall),
        .x_loc  (mem_x_loc),
        .y_loc  (mem_y_loc),
        .edges  (mem_edges),
        .result (edge_eval)
    );

    wire                         pe_valid;    
    wire [`RASTER_DIM_BITS-1:0]  pe_x_loc;
    wire [`RASTER_DIM_BITS-1:0]  pe_y_loc;
    wire [`RASTER_PID_BITS-1:0]  pe_pid;
    wire [2:0][2:0][`RASTER_DATA_BITS-1:0] pe_edges, pe_edges_e;
    wire [2:0][`RASTER_DATA_BITS-1:0] pe_extents;
    wire                         pe_ready;

    VX_shift_register #(
        .DATAW  (1 + 2 * `RASTER_DIM_BITS + `RASTER_PID_BITS + 9 * `RASTER_DATA_BITS + 3 * `RASTER_DATA_BITS),
        .DEPTH  (EDGE_FUNC_LATENCY),
        .RESETW (1)
    ) edge_func_shift_reg (
        .clk      (clk),
        .reset    (reset),
        .enable   (~edge_func_stall),
        .data_in  ({mem_unit_valid, mem_x_loc, mem_y_loc, mem_pid, mem_edges, mem_extents}),
        .data_out ({pe_valid,       pe_x_loc,  pe_y_loc,  pe_pid,  pe_edges,  pe_extents})
    );

    `EDGE_UPDATE (pe_edges_e, pe_edges, edge_eval);

    assign edge_func_stall = pe_valid && ~pe_ready;

    assign mem_unit_ready = ~edge_func_stall;

    wire [NUM_PES-1:0] pes_valid_in;    
    wire [NUM_PES-1:0][PRIM_DATA_WIDTH-1:0] pes_data_in;
    wire [NUM_PES-1:0] pes_ready_in;

    VX_stream_arb #(
        .NUM_OUTPUTS (NUM_PES),
        .DATAW       (PRIM_DATA_WIDTH),
        .ARBITER     ("R"),
        .BUFFERED    (1)       
    ) pe_req_arb (
        .clk        (clk),
        .reset      (reset),
        .valid_in   (pe_valid),
        .ready_in   (pe_ready),
        .data_in    ({pe_x_loc, pe_y_loc, pe_pid, pe_edges_e, pe_extents}),
        .data_out   (pes_data_in),        
        .valid_out  (pes_valid_in),        
        .ready_out  (pes_ready_in)
    );

    // track pending pe inputs 

    wire no_pending_pe_input;    

    wire mem_unit_fire = mem_unit_valid && mem_unit_ready;

    wire pes_input_fire = | (pes_valid_in & pes_ready_in);

    VX_pending_size #( 
        .SIZE (EDGE_FUNC_LATENCY + 2)
    ) pending_pe_inputs (
        .clk   (clk),
        .reset (reset),
        .incr  (mem_unit_fire),
        .decr  (pes_input_fire),
        .empty (no_pending_pe_input),
        `UNUSED_PIN (size),
        `UNUSED_PIN (full)
    );

    wire no_pe_input = ~mem_unit_busy 
                    && ~mem_unit_valid 
                    && no_pending_pe_input;

    VX_raster_req_if #(
        .NUM_LANES (OUTPUT_QUADS)
    ) pe_raster_req_if[NUM_PES]();

    VX_raster_req_if #(
        .NUM_LANES (OUTPUT_QUADS)
    ) raster_req_tmp_if[1]();

    wire [NUM_PES-1:0] pe_empty_out;

    // Generate all PEs
    for (genvar i = 0; i < NUM_PES; ++i) begin
        wire [`RASTER_DIM_BITS-1:0]       pe_x_loc_in;
        wire [`RASTER_DIM_BITS-1:0]       pe_y_loc_in;
        wire [`RASTER_PID_BITS-1:0]       pe_pid_in;
        wire [2:0][2:0][`RASTER_DATA_BITS-1:0] pe_edges_in;
        wire [2:0][`RASTER_DATA_BITS-1:0] pe_extents_in;

        wire pe_valid_out;        

        assign {pe_x_loc_in, pe_y_loc_in, pe_pid_in, pe_edges_in, pe_extents_in} = pes_data_in[i];

        `RESET_RELAY (pe_reset, reset);

        VX_raster_pe #(
            .INSTANCE_ID     (INSTANCE_ID),            
            .TILE_LOGSIZE    (TILE_LOGSIZE),
            .BLOCK_LOGSIZE   (BLOCK_LOGSIZE),
            .OUTPUT_QUADS    (OUTPUT_QUADS),
            .QUAD_FIFO_DEPTH (QUAD_FIFO_DEPTH)
        ) raster_pe (
            .clk        (clk),
            .reset      (pe_reset),

            .dcrs       (raster_dcrs),

            .valid_in   (pes_valid_in[i]),
            .x_loc_in   (pe_x_loc_in),
            .y_loc_in   (pe_y_loc_in),
            .x_max_in   (raster_dcrs.dst_xmax),
            .y_min_in   (raster_dcrs.dst_ymin),
            .y_max_in   (raster_dcrs.dst_ymax),
            .edges_in   (pe_edges_in),
            .pid_in     (pe_pid_in),
            .extents_in (pe_extents_in),
            .ready_in   (pes_ready_in[i]),

            .valid_out  (pe_valid_out),
            .stamps_out (pe_raster_req_if[i].stamps),
            .empty_out  (pe_empty_out[i]),
            .ready_out  (pe_raster_req_if[i].ready)
        );

        assign pe_raster_req_if[i].empty = (& pe_empty_out) && no_pe_input;
        assign pe_raster_req_if[i].valid = pe_valid_out || pe_raster_req_if[i].empty;        
    end

    `RESET_RELAY (raster_arb_reset, reset);

    VX_raster_arb #(
        .NUM_INPUTS (NUM_PES),
        .NUM_LANES  (OUTPUT_QUADS),
        .ARBITER    ("R"),
        .BUFFERED   (2)
    ) raster_arb (
        .clk        (clk),
        .reset      (raster_arb_reset),
        .req_in_if  (pe_raster_req_if),
        .req_out_if (raster_req_tmp_if)
    );

    `ASSIGN_VX_RASTER_REQ_IF (raster_req_if, raster_req_tmp_if[0]);

`ifdef CHIPSCOPE_RASTER
    ila_raster ila_raster_inst (
        .clk    (clk),
        .probe0 ({cache_rsp_if.data, cache_rsp_if.tag, cache_rsp_if.ready, cache_rsp_if.valid, cache_req_if.tag, cache_req_if.addr, cache_req_if.rw, cache_req_if.valid, cache_req_if.ready}),
        .probe1 ({pe_empty_out, no_pe_input, no_pending_pe_input, mem_unit_busy, mem_unit_ready, mem_unit_start, mem_unit_valid, raster_req_if.empty, raster_req_if.valid, raster_req_if.ready})
    );
`endif

`ifdef PERF_ENABLE
    wire [$clog2(RCACHE_NUM_REQS+1)-1:0] perf_mem_req_per_cycle;
    wire [$clog2(RCACHE_NUM_REQS+1)-1:0] perf_mem_rsp_per_cycle;
    wire [$clog2(RCACHE_NUM_REQS+1)+1-1:0] perf_pending_reads_cycle;

    wire [RCACHE_NUM_REQS-1:0] perf_mem_req_fire = cache_req_if.valid & cache_req_if.ready;
    wire [RCACHE_NUM_REQS-1:0] perf_mem_rsp_fire = cache_rsp_if.valid & cache_rsp_if.ready;

    `POP_COUNT(perf_mem_req_per_cycle, perf_mem_req_fire);
    `POP_COUNT(perf_mem_rsp_per_cycle, perf_mem_rsp_fire);

    reg [`PERF_CTR_BITS-1:0] perf_pending_reads;   
    assign perf_pending_reads_cycle = perf_mem_req_per_cycle - perf_mem_rsp_per_cycle;

    always @(posedge clk) begin
        if (reset) begin
            perf_pending_reads <= '0;
        end else begin
            perf_pending_reads <= $signed(perf_pending_reads) + `PERF_CTR_BITS'($signed(perf_pending_reads_cycle));
        end
    end

    wire perf_stall_cycle = raster_req_if.valid && ~raster_req_if.ready && ~raster_req_if.empty;

    reg [`PERF_CTR_BITS-1:0] perf_mem_reads;
    reg [`PERF_CTR_BITS-1:0] perf_mem_latency;
    reg [`PERF_CTR_BITS-1:0] perf_stall_cycles;

    always @(posedge clk) begin
        if (reset) begin
            perf_mem_reads    <= '0;
            perf_mem_latency  <= '0;
            perf_stall_cycles <= '0;
        end else begin
            perf_mem_reads    <= perf_mem_reads + `PERF_CTR_BITS'(perf_mem_req_per_cycle);
            perf_mem_latency  <= perf_mem_latency + `PERF_CTR_BITS'(perf_pending_reads);
            perf_stall_cycles <= perf_stall_cycles + `PERF_CTR_BITS'(perf_stall_cycle);
        end
    end

    assign perf_raster_if.mem_reads    = perf_mem_reads;
    assign perf_raster_if.mem_latency  = perf_mem_latency;
    assign perf_raster_if.stall_cycles = perf_stall_cycles;
`endif

`ifdef DBG_TRACE_RASTER
    always @(posedge clk) begin
        if (raster_req_if.valid && raster_req_if.ready) begin
            for (integer i = 0; i < OUTPUT_QUADS; ++i) begin
                `TRACE(1, ("%d: %s-out[%0d]: empty=%b, x=%0d, y=%0d, mask=%0d, pid=%0d, bcoords={{0x%0h, 0x%0h, 0x%0h}, {0x%0h, 0x%0h, 0x%0h}, {0x%0h, 0x%0h, 0x%0h}, {0x%0h, 0x%0h, 0x%0h}}\n",
                    $time, INSTANCE_ID, i, raster_req_if.empty,
                    raster_req_if.stamps[i].pos_x,  raster_req_if.stamps[i].pos_y, raster_req_if.stamps[i].mask, raster_req_if.stamps[i].pid,
                    raster_req_if.stamps[i].bcoords[0][0], raster_req_if.stamps[i].bcoords[1][0], raster_req_if.stamps[i].bcoords[2][0], 
                    raster_req_if.stamps[i].bcoords[0][1], raster_req_if.stamps[i].bcoords[1][1], raster_req_if.stamps[i].bcoords[2][1], 
                    raster_req_if.stamps[i].bcoords[0][2], raster_req_if.stamps[i].bcoords[1][2], raster_req_if.stamps[i].bcoords[2][2], 
                    raster_req_if.stamps[i].bcoords[0][3], raster_req_if.stamps[i].bcoords[1][3], raster_req_if.stamps[i].bcoords[2][3]));
            end
        end
    end
`endif

endmodule

///////////////////////////////////////////////////////////////////////////////

module VX_raster_unit_top #(
    parameter `STRING_TYPE INSTANCE_ID = "",
    parameter INSTANCE_IDX    = 0,
    parameter NUM_INSTANCES   = 1, 
    parameter NUM_PES         = 1,  // number of processing elements
    parameter TILE_LOGSIZE    = 5,  // tile log size
    parameter BLOCK_LOGSIZE   = 2,  // block log size
    parameter MEM_FIFO_DEPTH  = 8,  // memory queue size
    parameter QUAD_FIFO_DEPTH = 8,  // quad queue size
    parameter OUTPUT_QUADS    = 4   // number of output quads    
) (
    input wire                              clk,
    input wire                              reset,
    
    input wire                              dcr_write_valid,
    input wire [`VX_DCR_ADDR_WIDTH-1:0]     dcr_write_addr,
    input wire [`VX_DCR_DATA_WIDTH-1:0]     dcr_write_data,

    output wire                             raster_req_valid,  
    output raster_stamp_t [OUTPUT_QUADS-1:0] raster_req_stamps,
    output wire                             raster_req_empty,    
    input wire                              raster_req_ready,

    output wire [RCACHE_NUM_REQS-1:0]       cache_req_valid,
    output wire [RCACHE_NUM_REQS-1:0]       cache_req_rw,
    output wire [RCACHE_NUM_REQS-1:0][RCACHE_WORD_SIZE-1:0] cache_req_byteen,
    output wire [RCACHE_NUM_REQS-1:0][RCACHE_ADDR_WIDTH-1:0] cache_req_addr,
    output wire [RCACHE_NUM_REQS-1:0][RCACHE_WORD_SIZE*8-1:0] cache_req_data,
    output wire [RCACHE_NUM_REQS-1:0][RCACHE_TAG_WIDTH-1:0] cache_req_tag,
    input  wire [RCACHE_NUM_REQS-1:0]       cache_req_ready,

    input wire  [RCACHE_NUM_REQS-1:0]       cache_rsp_valid,
    input wire  [RCACHE_NUM_REQS-1:0][RCACHE_WORD_SIZE*8-1:0] cache_rsp_data,
    input wire  [RCACHE_NUM_REQS-1:0][RCACHE_TAG_WIDTH-1:0] cache_rsp_tag,
    output wire [RCACHE_NUM_REQS-1:0]       cache_rsp_ready
);

    VX_raster_perf_if perf_raster_if();

    VX_dcr_write_if dcr_write_if();

    assign dcr_write_if.valid = dcr_write_valid;
    assign dcr_write_if.addr = dcr_write_addr;
    assign dcr_write_if.data = dcr_write_data;

    VX_raster_req_if #(
        .NUM_LANES (OUTPUT_QUADS)
    ) raster_req_if();

    assign raster_req_valid = raster_req_if.valid;
    assign raster_req_stamps = raster_req_if.stamps;
    assign raster_req_if.empty=raster_req_empty;
    assign raster_req_if.ready = raster_req_ready;

    VX_cache_req_if #(
        .NUM_REQS  (RCACHE_NUM_REQS), 
        .WORD_SIZE (RCACHE_WORD_SIZE), 
        .TAG_WIDTH (RCACHE_TAG_WIDTH)
    ) cache_req_if();

    VX_cache_rsp_if #(
        .NUM_REQS  (RCACHE_NUM_REQS), 
        .WORD_SIZE (RCACHE_WORD_SIZE), 
        .TAG_WIDTH (RCACHE_TAG_WIDTH)
    ) cache_rsp_if();

    assign cache_req_valid = cache_req_if.valid;
    assign cache_req_rw = cache_req_if.rw;
    assign cache_req_byteen = cache_req_if.byteen;
    assign cache_req_addr = cache_req_if.addr;
    assign cache_req_data = cache_req_if.data;
    assign cache_req_tag = cache_req_if.tag;
    assign cache_req_if.ready = cache_req_ready;

    assign cache_rsp_if.valid = cache_rsp_valid;
    assign cache_rsp_if.tag = cache_rsp_tag;
    assign cache_rsp_if.data = cache_rsp_data;
    assign cache_rsp_ready = cache_rsp_if.ready;
    
    VX_raster_unit #( 
        .INSTANCE_ID     (INSTANCE_ID),
        .INSTANCE_IDX    (INSTANCE_IDX),
        .NUM_INSTANCES   (NUM_INSTANCES),
        .NUM_PES         (NUM_PES),
        .TILE_LOGSIZE    (TILE_LOGSIZE),
        .BLOCK_LOGSIZE   (BLOCK_LOGSIZE),
        .MEM_FIFO_DEPTH  (MEM_FIFO_DEPTH),
        .QUAD_FIFO_DEPTH (QUAD_FIFO_DEPTH),
        .OUTPUT_QUADS    (OUTPUT_QUADS)
    ) raster_unit (
        .clk           (clk),
        .reset         (reset),
    `ifdef PERF_ENABLE
        .perf_raster_if(perf_raster_if),
    `endif 
        .dcr_write_if  (dcr_write_if),
        .raster_req_if (raster_req_if),
        .cache_req_if  (cache_req_if),
        .cache_rsp_if  (cache_rsp_if)
    );

endmodule
