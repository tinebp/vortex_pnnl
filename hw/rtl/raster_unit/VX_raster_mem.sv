`include "VX_raster_define.vh"

// Memory interface for the rasterization unit.
// Performs the following:
//  1. Break the request in tile and primitive fetch requests
//  2. Form an FSM to keep a track of the return value types
//  3. Store primitive data in an elastic buffer

module VX_raster_mem #(
    parameter `STRING_TYPE INSTANCE_ID = "",
    parameter TILE_LOGSIZE  = 5,
    parameter QUEUE_SIZE    = 8
) (
    input wire clk,
    input wire reset,

    // Device configurations
    raster_dcrs_t                       dcrs,

    // Memory interface
    VX_cache_req_if.master              cache_req_if,
    VX_cache_rsp_if.slave               cache_rsp_if,

    // Inputs
    input wire                          start,
    output wire                         busy,

    // Outputs
    output wire                         valid_out,
    output wire [`RASTER_PID_BITS-1:0]  pid_out,
    output wire [`RASTER_DIM_BITS-1:0]  x_loc_out,
    output wire [`RASTER_DIM_BITS-1:0]  y_loc_out,
    output wire [2:0][2:0][`RASTER_DATA_BITS-1:0] edges_out,    
    input wire                          ready_out
);
    `UNUSED_VAR (dcrs)

    localparam NUM_REQS         = RASTER_MEM_REQS;
    localparam FSM_BITS         = 2;
    localparam FETCH_FLAG_BITS  = 2;
    localparam TAG_WIDTH        = `RASTER_PID_BITS + FETCH_FLAG_BITS;

    localparam STATE_IDLE       = 2'b00;
    localparam STATE_TILE       = 2'b01;
    localparam STATE_PRIM       = 2'b10;
    
    localparam FETCH_FLAG_TILE  = 2'b00;
    localparam FETCH_FLAG_PID   = 2'b01;
    localparam FETCH_FLAG_PDATA = 2'b10;
    
    // A primitive data contains (x_loc, y_loc, pid, edges)
    localparam PRIM_DATA_WIDTH = 2 * `RASTER_DIM_BITS + 9 * `RASTER_DATA_BITS + `RASTER_PID_BITS;

    // Storage to cycle through all primitives and tiles
    reg [`RASTER_DCR_DATA_BITS-1:0] curr_tbuf_addr;
    reg [`RASTER_DCR_DATA_BITS-1:0] curr_pbuf_addr;
    reg [`RASTER_PID_BITS-1:0]      curr_pid_reqs;
    reg [`RASTER_PID_BITS-1:0]      curr_pid_rsps;
    reg [`RASTER_TILE_BITS-1:0]     curr_num_tiles;
    reg [`RASTER_DIM_BITS-1:0]      curr_x_loc;
    reg [`RASTER_DIM_BITS-1:0]      curr_y_loc;

    // Output buffer
    wire buf_in_valid;
    wire buf_in_ready;

    // Memory request
    reg mem_req_valid, mem_req_valid_qual;
    reg [NUM_REQS-1:0] mem_req_mask;
    reg [8:0][`RASTER_DCR_DATA_BITS-1:0] mem_req_addr;
    reg [TAG_WIDTH-1:0] mem_req_tag;
    wire mem_req_ready;
    
    // Memory response
    wire mem_rsp_valid;
    wire [8:0][`RASTER_DATA_BITS-1:0] mem_rsp_data;    
    wire [TAG_WIDTH-1:0] mem_rsp_tag;
    wire mem_rsp_ready;
    
     // Primitive info
    wire [`RASTER_DCR_DATA_BITS-1:0] pbuf_addr;
    wire prim_id_rsp_valid;
    wire prim_data_rsp_valid;
    wire prim_addr_rsp_valid;
    wire prim_addr_rsp_ready;
    wire [8:0][`RASTER_DATA_BITS-1:0] prim_mem_addr;
    wire [`RASTER_PID_BITS-1:0] primitive_id;

    // Memory fetch FSM

    reg [FSM_BITS-1:0] state;
    
    wire is_prim_id_req   = (mem_req_tag[FETCH_FLAG_BITS-1:0] == FETCH_FLAG_PID);
    wire is_prim_id_rsp   = (mem_rsp_tag[FETCH_FLAG_BITS-1:0] == FETCH_FLAG_PID);

    wire is_prim_data_req = (mem_req_tag[FETCH_FLAG_BITS-1:0] == FETCH_FLAG_PDATA);
    wire is_prim_data_rsp = (mem_rsp_tag[FETCH_FLAG_BITS-1:0] == FETCH_FLAG_PDATA);

    wire mem_req_fire = mem_req_valid_qual && mem_req_ready;

    wire prim_addr_rsp_fire = prim_addr_rsp_valid && prim_addr_rsp_ready;

    wire prim_data_rsp_fire = prim_data_rsp_valid && mem_rsp_ready;

    // tile header info
    wire [15:0] th_tile_pos_x  = mem_rsp_data[0][0  +: 16];
    wire [15:0] th_tile_pos_y  = mem_rsp_data[0][16 +: 16];
    wire [15:0] th_pbuf_offset = mem_rsp_data[1][0 +: 16];
    wire [15:0] th_prim_index  = mem_rsp_data[1][16 +: 16];

    // calculate primitive buffer address
    assign pbuf_addr = curr_tbuf_addr + `RASTER_DCR_DATA_BITS'(th_pbuf_offset);
    
    // scheduler FSM
    always @(posedge clk) begin
        if (reset) begin
            state <= STATE_IDLE; 
            mem_req_valid <= 0;    
        end else begin
            // deassert memory request when fired
            if (mem_req_fire) begin
                mem_req_valid <= 0; 
            end

            case (state)
            STATE_IDLE: begin
                if (start) begin
                    // fetch the next tile header
                    state           <= STATE_TILE;         
                    mem_req_valid   <= 1;
                    mem_req_addr[0] <= dcrs.tbuf_addr;
                    mem_req_addr[1] <= dcrs.tbuf_addr + 4;
                    mem_req_mask    <= 9'b11;
                    mem_req_tag     <= TAG_WIDTH'(FETCH_FLAG_TILE);
                    // set tile counters
                    curr_tbuf_addr  <= dcrs.tbuf_addr + 8;
                    curr_num_tiles  <= dcrs.tile_count;
                end
            end
            STATE_TILE: begin
                if (mem_rsp_valid) begin
                    // handle tile header response
                    state           <= STATE_PRIM;
                    curr_x_loc      <= `RASTER_DIM_BITS'(th_tile_pos_x << TILE_LOGSIZE);
                    curr_y_loc      <= `RASTER_DIM_BITS'(th_tile_pos_y << TILE_LOGSIZE);                    
                    // fetch next primitive pid
                    mem_req_valid   <= 1;   
                    mem_req_addr[0] <= pbuf_addr;
                    mem_req_mask    <= 9'b1;                    
                    mem_req_tag     <= TAG_WIDTH'(FETCH_FLAG_PID);
                    // set primitive counters
                    curr_pbuf_addr  <= pbuf_addr;
                    curr_pid_reqs   <= `RASTER_PID_BITS'(th_prim_index);
                    curr_pid_rsps   <= `RASTER_PID_BITS'(th_prim_index);
                end
            end
            STATE_PRIM: begin
                // handle memory submissions
                if (mem_req_fire) begin
                    if (is_prim_id_req) begin
                        // update pid counters
                        curr_pbuf_addr <= curr_pbuf_addr + 4;
                        curr_pid_reqs  <= curr_pid_reqs - `RASTER_PID_BITS'(1);
                    end

                    if ((curr_pid_reqs > 1) 
                     || (curr_pid_reqs == 1 && ~is_prim_id_req)) begin
                        // fetch next primitive pid
                        mem_req_valid   <= 1;                        
                        mem_req_mask    <= 9'b1;
                        mem_req_addr[0] <= curr_pbuf_addr + (is_prim_id_req ? 4 : 0);
                        mem_req_tag     <= TAG_WIDTH'(FETCH_FLAG_PID);                        
                    end
                end

                // handle primitive address response  
                if (prim_addr_rsp_fire) begin                    
                    mem_req_valid <= 1;                    
                    mem_req_mask  <= 9'b111111111;
                    mem_req_addr  <= prim_mem_addr;
                    mem_req_tag   <= TAG_WIDTH'({primitive_id, FETCH_FLAG_PDATA});
                end 
                
                // handle primitive data response
                if (prim_data_rsp_fire) begin
                    if (curr_pid_rsps == 1) begin
                        if (curr_num_tiles == 1) begin
                            // done, return to idle
                            state <= STATE_IDLE;
                        end else begin
                            // fetch the next tile header
                            state           <= STATE_TILE;
                            mem_req_valid   <= 1;
                            mem_req_mask    <= 9'b11;
                            mem_req_addr[0] <= curr_tbuf_addr;
                            mem_req_addr[1] <= curr_tbuf_addr + 4;                            
                            mem_req_tag     <= TAG_WIDTH'(FETCH_FLAG_TILE);
                            curr_tbuf_addr  <= curr_tbuf_addr + 8;
                        end
                        // update tile counter
                        curr_num_tiles <= curr_num_tiles - `RASTER_TILE_BITS'(1);
                    end
                    // update pid counter
                    curr_pid_rsps <= curr_pid_rsps - `RASTER_PID_BITS'(1);
                end
            end
            default:;
            endcase
        end
    end

    // Memory streamer

    // ensure that we have space in the output buffer to prevent memory deadlock
    wire pending_output_full;
    VX_pending_size #( 
        .SIZE (QUEUE_SIZE-1)
    ) pending_reads (
        .clk   (clk),
        .reset (reset),
        .incr  (mem_req_fire && is_prim_id_req),
        .decr  (valid_out && ready_out),
        .full  (pending_output_full),
        `UNUSED_PIN (size),
        `UNUSED_PIN (empty)
    );    
    assign mem_req_valid_qual = mem_req_valid && (~is_prim_id_req || ~pending_output_full);

    // the memory response is for primitive id
    assign prim_id_rsp_valid = mem_rsp_valid && is_prim_id_rsp;

    // the memory response is for primitive data
    assign prim_data_rsp_valid = mem_rsp_valid && is_prim_data_rsp;

    // stall primitive address handling if primitive data fetch stalls
    wire prim_data_req_stall = mem_req_valid && is_prim_data_req && ~mem_req_ready;
    assign prim_addr_rsp_ready = ~prim_data_req_stall || ~prim_addr_rsp_valid;

    // Push primitive data into output buffer
    assign buf_in_valid = prim_data_rsp_valid;

    // stall the memory response
    assign mem_rsp_ready = (~prim_id_rsp_valid || prim_addr_rsp_ready) 
                        && (~prim_data_rsp_valid || buf_in_ready);

    wire [8:0][RCACHE_ADDR_WIDTH-1:0] mem_req_addr_w;
    wire [8:0][RCACHE_WORD_SIZE-1:0] mem_req_byteen;
    for (genvar i = 0; i < 9; ++i) begin
        assign mem_req_addr_w[i] = mem_req_addr[i][(32 - RCACHE_ADDR_WIDTH) +: RCACHE_ADDR_WIDTH];
        assign mem_req_byteen[i] = {RCACHE_WORD_SIZE{1'b1}};
    end

    // schedule memory request
    VX_mem_scheduler #(
        .INSTANCE_ID  ($sformatf("%s-memsched", INSTANCE_ID)),
        .NUM_REQS     (NUM_REQS), 
        .NUM_BANKS    (RCACHE_NUM_REQS),
        .ADDR_WIDTH   (RCACHE_ADDR_WIDTH),
        .DATA_WIDTH   (`RASTER_DATA_BITS),
        .QUEUE_SIZE   (`RASTER_MEM_QUEUE_SIZE),
        .TAG_WIDTH    (TAG_WIDTH),
        .CORE_OUT_REG (2),
        .MEM_OUT_REG  (3)
    ) mem_scheduler (
        .clk            (clk),
        .reset          (reset),

        // Input request
        .req_valid      (mem_req_valid_qual),
        .req_rw         (1'b0),
        .req_mask       (mem_req_mask),
        .req_byteen     (mem_req_byteen),
        .req_addr       (mem_req_addr_w),
        `UNUSED_PIN     (req_data),
        .req_tag        (mem_req_tag),
        `UNUSED_PIN     (req_empty),
        .req_ready      (mem_req_ready),
        `UNUSED_PIN     (write_notify),
        
        // Output response
        .rsp_valid      (mem_rsp_valid),
        `UNUSED_PIN     (rsp_mask),
        .rsp_data       (mem_rsp_data),
        .rsp_tag        (mem_rsp_tag),
        `UNUSED_PIN     (rsp_eop),
        .rsp_ready      (mem_rsp_ready),

        // Memory request
        .mem_req_valid  (cache_req_if.valid),
        .mem_req_rw     (cache_req_if.rw),
        .mem_req_byteen (cache_req_if.byteen),
        .mem_req_addr   (cache_req_if.addr),
        .mem_req_data   (cache_req_if.data),
        .mem_req_tag    (cache_req_if.tag),
        .mem_req_ready  (cache_req_if.ready),

        // Memory response
        .mem_rsp_valid  (cache_rsp_if.valid),
        .mem_rsp_data   (cache_rsp_if.data),
        .mem_rsp_tag    (cache_rsp_if.tag),
        .mem_rsp_ready  (cache_rsp_if.ready)
    );

    wire [`RASTER_DATA_BITS-1:0] prim_mem_offset;

    VX_multiplier #(
        .A_WIDTH (`RASTER_DATA_BITS),
        .B_WIDTH (`RASTER_STRIDE_BITS),
        .R_WIDTH (`RASTER_DATA_BITS),
        .LATENCY (`LATENCY_IMUL)
    ) multiplier (
        .clk    (clk),
        .enable (prim_addr_rsp_ready),
        .dataa  (mem_rsp_data[0]),
        .datab  (dcrs.pbuf_stride),
        .result (prim_mem_offset)
    );

    for (genvar i = 0; i < 9; ++i) begin
        assign prim_mem_addr[i] = dcrs.pbuf_addr + prim_mem_offset + 4 * i;
    end

    VX_shift_register #(
        .DATAW  (1 + `RASTER_PID_BITS),
        .DEPTH  (`LATENCY_IMUL),
        .RESETW (1)
    ) mul_shift_reg (
        .clk      (clk),
        .reset    (reset),
        .enable   (prim_addr_rsp_ready),
        .data_in  ({prim_id_rsp_valid,   mem_rsp_data[0][`RASTER_PID_BITS-1:0]}),
        .data_out ({prim_addr_rsp_valid, primitive_id})
    );   

    // Output buffer
    VX_elastic_buffer #(
        .DATAW   (PRIM_DATA_WIDTH), 
        .SIZE    (QUEUE_SIZE),
        .OUT_REG (QUEUE_SIZE > 2)
    ) buf_out (
        .clk        (clk),
        .reset      (reset),
        .valid_in   (buf_in_valid),
        .ready_in   (buf_in_ready),
        .data_in    ({curr_x_loc, curr_y_loc, mem_rsp_data, mem_rsp_tag[FETCH_FLAG_BITS +: `RASTER_PID_BITS]}),                
        .data_out   ({x_loc_out,  y_loc_out,  edges_out,    pid_out}),
        .valid_out  (valid_out),
        .ready_out  (ready_out)
    );

    // busy ?
    assign busy = (state != STATE_IDLE);

`ifdef DBG_TRACE_RASTER
    always @(posedge clk) begin
        if (valid_out && ready_out) begin
            `TRACE(2, ("%d: %s-mem-out: x=%0d, y=%0d, pid=%0d, edge={{0x%0h, 0x%0h, 0x%0h}, {0x%0h, 0x%0h, 0x%0h}, {0x%0h, 0x%0h, 0x%0h}}\n",
                $time, INSTANCE_ID, x_loc_out, y_loc_out, pid_out,
                edges_out[0][0], edges_out[0][1], edges_out[0][2],
                edges_out[1][0], edges_out[1][1], edges_out[1][2],
                edges_out[2][0], edges_out[2][1], edges_out[2][2]));
        end 
    end
`endif

endmodule
