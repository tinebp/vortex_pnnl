// Quad evaluator block
// Functionality: Receives a 2x2 quad with primitive information
//     check whether quad pixels are within the primitive

`include "VX_raster_define.vh"

module VX_raster_qe #(
    parameter SLICE_ID  = 0,
    parameter NUM_QUADS = 4
) (
    input wire clk,
    input wire reset, 

    // Device configurations
    raster_dcrs_t dcrs,

    output wire                                         empty,

    input wire                                          enable,   
    
    // Inputs    
    input wire                                          valid_in,
    input wire [`RASTER_PID_BITS-1:0]                   pid_in,
    input wire [NUM_QUADS-1:0][`RASTER_DIM_BITS-1:0]    x_loc_in,
    input wire [NUM_QUADS-1:0][`RASTER_DIM_BITS-1:0]    y_loc_in,
    input wire [NUM_QUADS-1:0][2:0][2:0][`RASTER_DATA_BITS-1:0] edges_in,

    // Outputs
    output wire [NUM_QUADS-1:0]                         valid_out,
    output wire [`RASTER_PID_BITS-1:0]                  pid_out,    
    output wire [NUM_QUADS-1:0][3:0]                    mask_out,    
    output wire [NUM_QUADS-1:0][`RASTER_DIM_BITS-1:0]   x_loc_out,
    output wire [NUM_QUADS-1:0][`RASTER_DIM_BITS-1:0]   y_loc_out,    
    output wire [NUM_QUADS-1:0][3:0][2:0][`RASTER_DATA_BITS-1:0] bcoords_out
);
    `UNUSED_VAR (dcrs)

    wire [NUM_QUADS-1:0] valid;
    wire [NUM_QUADS-1:0][3:0][2:0][`RASTER_DATA_BITS-1:0] bcoords;
    wire [NUM_QUADS-1:0][3:0] mask;

     // edge evaluation
    for (genvar q = 0; q < NUM_QUADS; ++q) begin
        wire signed [1:0][1:0][2:0][`RASTER_DATA_BITS-1:0] edge_eval;              
        
        for (genvar i = 0; i < 2; ++i) begin
            for (genvar j = 0; j < 2; ++j) begin
                for (genvar k = 0; k < 3; ++k) begin
                    assign edge_eval[i][j][k] = i * edges_in[q][k][0] + j * edges_in[q][k][1] + edges_in[q][k][2];
                end
            end
        end        
        
        for (genvar i = 0; i < 2; ++i) begin
            for (genvar j = 0; j < 2; ++j) begin            
                assign mask[q][2 * j + i] = (edge_eval[i][j][0] >= 0) && (edge_eval[i][j][1] >= 0) && (edge_eval[i][j][2] >= 0);
                assign bcoords[q][2 * j + i] = edge_eval[i][j];
            end
        end

        assign valid[q] = valid_in && (| mask[q]);
    end

    VX_pipe_register #(
        .DATAW  (1 + NUM_QUADS + `RASTER_PID_BITS + NUM_QUADS * (4 + 2 * `RASTER_DIM_BITS + 4 * 3 * `RASTER_DATA_BITS)),
        .RESETW (1)
    ) pipe_reg (
        .clk      (clk),
        .reset    (reset),
        .enable   (enable),
        .data_in  ({~valid_in, valid,     pid_in,  mask,     x_loc_in,  y_loc_in,  bcoords}),
        .data_out ({empty,     valid_out, pid_out, mask_out, x_loc_out, y_loc_out, bcoords_out})
    );

endmodule
