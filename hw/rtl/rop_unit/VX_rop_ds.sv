`include "VX_rop_define.vh"

module VX_rop_ds #(
    parameter CLUSTER_ID = 0,
    parameter NUM_LANES  = 4
) (
    input wire clk,
    input wire reset,

    // Depth Test
    input wire [`NUM_LANES-1:0][`ROP_DEPTH_FUNC_BITS-1:0] depth_func,
    input wire [`NUM_LANES-1:0][`ROP_DEPTH_BITS-1:0] depth_ref,
    input wire [`NUM_LANES-1:0][`ROP_DEPTH_BITS-1:0] depth_val,
    input wire [`NUM_LANES-1:0][`ROP_DEPTH_BITS-1:0] depth_mask,

    output wire [`ROP_DEPTH_BITS-1:0] depth_out,

    // Stencil Test
    input wire [`ROP_STENCIL_BITS-1:0]    stencil_val,
    input wire                            backface,

    input wire [`ROP_DEPTH_FUNC_BITS-1:0] stencil_front_func,    
    input wire [`ROP_STENCIL_OP_BITS-1:0] stencil_front_zpass,
    input wire [`ROP_STENCIL_OP_BITS-1:0] stencil_front_zfail,
    input wire [`ROP_STENCIL_OP_BITS-1:0] stencil_front_fail,
    input wire [`ROP_STENCIL_BITS-1:0]    stencil_front_mask,
    input wire [`ROP_STENCIL_BITS-1:0]    stencil_front_ref,
    input wire [`ROP_DEPTH_FUNC_BITS-1:0] stencil_back_func,    
    input wire [`ROP_STENCIL_OP_BITS-1:0] stencil_back_zpass,
    input wire [`ROP_STENCIL_OP_BITS-1:0] stencil_back_zfail,
    input wire [`ROP_STENCIL_OP_BITS-1:0] stencil_back_fail,
    input wire [`ROP_STENCIL_BITS-1:0]    stencil_back_mask,
    input wire [`ROP_STENCIL_BITS-1:0]    stencil_back_ref,

    output wire [`ROP_STENCIL_BITS-1:0]  stencil_out,
    output wire [`ROP_DEPTH_BITS+`ROP_STENCIL_BITS-1:0] mask_out

);

    reg  [`ROP_DEPTH_BITS-1:0]      depth_result;

    wire [`ROP_DEPTH_FUNC_BITS-1:0] stencil_func;
    reg  [`ROP_STENCIL_OP_BITS-1:0] stencil_op;
    wire [`ROP_STENCIL_BITS-1:0]    stencil_mask;
    wire [`ROP_STENCIL_BITS-1:0]    stencil_ref;
    wire [`ROP_STENCIL_BITS-1:0]    stencil_result;

    wire [`ROP_STENCIL_BITS-1:0]    stencil_ref_m;
    wire [`ROP_STENCIL_BITS-1:0]    stencil_val_m;

    reg  [`ROP_DEPTH_BITS+`ROP_STENCIL_BITS-1:0] stencil_write_mask;

    wire dpass;
    wire spass;

    ///////////////////////////////////////////////////////////////

    // Depth Test

    VX_rop_compare #(
        .DATAW (24)
    ) depth_compare (
        .func   (depth_func),
        .a      (depth_ref),
        .b      (depth_val),
        .result (dpass)
    );

    always @(*) begin
        if (dpass & (| depth_mask))
            depth_result = depth_ref;
        else    
            depth_result = depth_val;
    end

    ///////////////////////////////////////////////////////////////

    // Stencil Test

    assign stencil_func = backface ? stencil_back_func : stencil_front_func;
    assign stencil_mask = backface ? stencil_back_mask : stencil_front_mask;
    assign stencil_ref  = backface ? stencil_back_ref : stencil_front_ref;

    assign stencil_ref_m = stencil_ref & stencil_mask;
    assign stencil_val_m = stencil_val & stencil_mask;

    VX_rop_compare #(
        .DATAW (8)
    ) stencil_compare (
        .func   (stencil_func),
        .a      (stencil_ref_m),
        .b      (stencil_val_m),
        .result (spass)
    );

    always @(*) begin
        stencil_write_mask = {stencil_mask, {`ROP_DEPTH_BITS{1'b0}}};
        if (spass) begin
            if (dpass) begin
                if (| depth_mask)
                    stencil_write_mask = stencil_write_mask | 32'hFFFFFF;
                stencil_op = backface ? stencil_back_zpass : stencil_front_zpass;
            end else
                stencil_op = backface ? stencil_back_zfail : stencil_front_zfail;
        end else
            stencil_op = backface ? stencil_back_fail : stencil_front_fail;
    end

    VX_rop_stencil_op #(
        .DATAW (8)
    ) stencil_op_ (
        .stencil_op     (stencil_op),
        .stencil_ref    (stencil_ref),
        .stencil_val    (stencil_val),
        .stencil_result (stencil_result)
    );

    ///////////////////////////////////////////////////////////////

    VX_pipe_register #(
        .DATAW	(`ROP_DEPTH_BITS + `ROP_STENCIL_BITS + (`ROP_DEPTH_BITS + `ROP_STENCIL_BITS)),
        .RESETW (1)
    ) pipe_reg (
        .clk      (clk),
        .reset    (reset),
        .enable   (1'b1),
        .data_in  ({depth_result, stencil_result, stencil_write_mask}),
        .data_out ({depth_out,    stencil_out,    mask_out})
    );

    ///////////////////////////////////////////////////////////////

endmodule