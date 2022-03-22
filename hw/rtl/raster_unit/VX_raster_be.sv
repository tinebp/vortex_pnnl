// Block level evaluator
// Functionality: Receives a block of AxA (where A is pow(2))
//     1. Breaks it into quad and runs quad evaluators on it
//     2. Stores the result in quad queues
//     3. Queues direction read as outputs

`include "VX_raster_define.vh"

module VX_raster_be #(
    parameter RASTER_BLOCK_SIZE       = 4,
    parameter RASTER_QUAD_OUTPUT_RATE = 2,
    parameter RASTER_QUAD_FIFO_DEPTH  = 16
) (
    // Standard inputs
    input logic clk, reset,
    input logic input_valid, // to indicate current input is a valid update
    input logic pop,         // to fetch data from the quad queue
    
    output logic empty,      // to indicate no data left in data queue
    output logic ready,      // to indicate it has sent all previous quad data

    // Block related input data
    input logic [`RASTER_TILE_DATA_BITS-1:0]                   x_loc, y_loc,
    // edge equation data for the 3 edges and ax+by+c
    input logic signed [`RASTER_PRIMITIVE_DATA_BITS-1:0]       edges[2:0][2:0],
    // edge function computation value propagated
    input logic signed [`RASTER_PRIMITIVE_DATA_BITS-1:0]       edge_func_val[2:0],

    // Quad related output data
    output logic [`RASTER_TILE_DATA_BITS-1:0]     out_quad_x_loc[RASTER_QUAD_OUTPUT_RATE-1:0],
    output logic [`RASTER_TILE_DATA_BITS-1:0]     out_quad_y_loc[RASTER_QUAD_OUTPUT_RATE-1:0],
    output logic [3:0]                            out_quad_masks[RASTER_QUAD_OUTPUT_RATE-1:0],
    output logic                                  valid[RASTER_QUAD_OUTPUT_RATE-1:0]
);

    // Local parameter setup
    localparam RASTER_QUAD_NUM           = RASTER_BLOCK_SIZE/2;
    localparam RASTER_QUAD_SPACE         = RASTER_QUAD_NUM*RASTER_QUAD_NUM;
    localparam RASTER_QUAD_ARBITER_RANGE = RASTER_QUAD_SPACE/RASTER_QUAD_OUTPUT_RATE;
    localparam ARBITER_BITS              = $clog2(RASTER_QUAD_ARBITER_RANGE) + 1;

    // Temporary (temp_) for combinatorial part, quad_ register for data storage
    logic [`RASTER_TILE_DATA_BITS-1:0]   temp_quad_x_loc[RASTER_QUAD_SPACE-1:0],
        quad_x_loc[RASTER_QUAD_SPACE-1:0];
    logic [`RASTER_TILE_DATA_BITS-1:0]   temp_quad_y_loc[RASTER_QUAD_SPACE-1:0],
        quad_y_loc[RASTER_QUAD_SPACE-1:0];
    logic [3:0] temp_quad_masks[RASTER_QUAD_SPACE-1:0], 
        quad_masks[RASTER_QUAD_SPACE-1:0];

    // Wire to hold the edge function values for quad evaluation
    logic signed [`RASTER_PRIMITIVE_DATA_BITS-1:0] local_edge_func_val[RASTER_QUAD_SPACE-1:0][2:0];

    // Status signal to log if it is working on valid data
    logic valid_data;
    // Fifo and arbiter signals
    logic full, push;
    logic [ARBITER_BITS-1:0] arbiter_index;
    // Per fifo signals
    logic [RASTER_QUAD_OUTPUT_RATE-1:0] full_flag, empty_flag;

    // Generate the RASTER_QUAD_NUM x RASTER_QUAD_NUM quad evaluators
    for (genvar i = 0; i < RASTER_QUAD_NUM; ++i) begin
        for (genvar j = 0; j < RASTER_QUAD_NUM; ++j) begin
            always_comb begin
                temp_quad_x_loc[i*RASTER_QUAD_NUM+j] = x_loc + i*2;
                temp_quad_y_loc[i*RASTER_QUAD_NUM+j] = y_loc + j*2;
                for (integer k = 0; k < 3; ++k)
                    local_edge_func_val[i*RASTER_QUAD_NUM+j][k] = edge_func_val[k] + i*2*edges[k][0] + j*2*edges[k][1];
            end
            VX_raster_qe qe (
                .edges(edges),
                .edge_func_val(local_edge_func_val[i*RASTER_QUAD_NUM+j]),
                .masks(temp_quad_masks[i*RASTER_QUAD_NUM+j])
            );
        end
    end

    // Store the temp results in registers
    for(genvar i = 0; i < RASTER_QUAD_SPACE; ++i) begin
        // Save the temp data into quad registers to prevent overwrite by redundant data
        always @(posedge clk) begin
            if (input_valid == 1) begin // overwrite only the first time
                quad_x_loc[i] <= temp_quad_x_loc[i];
                quad_y_loc[i] <= temp_quad_y_loc[i];
                quad_masks[i] <= temp_quad_masks[i];
            end
        end
    end

    // Simple arbiter implementation
    always @(posedge clk) begin
        // Reset condition
        if (reset == 1) begin
            arbiter_index <= RASTER_QUAD_ARBITER_RANGE[ARBITER_BITS-1:0] - 1;
            valid_data <= 0;
        end
        // Initialization condition
        else if (input_valid == 1) begin
            arbiter_index <= 0;
            valid_data <= 1;
        end
        // Arbitration condition
        else if (full == 0 && push == 1)
            arbiter_index <= arbiter_index + 1;
        else if (ready)
            valid_data <= 0;
    end

    assign push = (arbiter_index < (RASTER_QUAD_ARBITER_RANGE[ARBITER_BITS-1:0])) && !full;
    assign ready = (arbiter_index >= (RASTER_QUAD_ARBITER_RANGE[ARBITER_BITS-1:0]-1)) && !full;

    localparam FIFO_DATA_WIDTH = 2*`RASTER_TILE_DATA_BITS + 4 + 1;
    // Generate the required number of FIFOs
    for (genvar i = 0; i < RASTER_QUAD_OUTPUT_RATE; ++i) begin
        // Quad queue
        logic [FIFO_DATA_WIDTH-1:0] fifo_push_data, fifo_pop_data;
        assign fifo_push_data = (arbiter_index*RASTER_QUAD_OUTPUT_RATE + i) < RASTER_QUAD_SPACE ?
            {
                quad_x_loc[arbiter_index*RASTER_QUAD_OUTPUT_RATE + i],
                quad_y_loc[arbiter_index*RASTER_QUAD_OUTPUT_RATE + i],
                quad_masks[arbiter_index*RASTER_QUAD_OUTPUT_RATE + i],
                (1'b1 && valid_data)
            } : {FIFO_DATA_WIDTH{1'bz}};

        logic fifo_valid;
        assign {out_quad_x_loc[i], out_quad_y_loc[i], out_quad_masks[i], fifo_valid} = fifo_pop_data;
        assign valid[i] = fifo_valid && !empty_flag[i];
        VX_fifo_queue #(
            .DATAW	    (FIFO_DATA_WIDTH),
            .SIZE       (RASTER_QUAD_FIFO_DEPTH),
            .OUT_REG    (1)
        ) tile_fifo_queue (
            .clk        (clk),
            .reset      (reset),
            .push       (push),
            .pop        (pop),
            .data_in    (fifo_push_data),
            .data_out   (fifo_pop_data),
            .full       (full_flag[i]),
            .empty      (empty_flag[i]),
            `UNUSED_PIN (alm_full),
            `UNUSED_PIN (alm_empty),
            `UNUSED_PIN (size)
        );
    end

    assign full = &(full_flag);
    assign empty = &(empty_flag);

endmodule