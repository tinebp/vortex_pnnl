`include "VX_rop_define.vh"

module VX_rop_dcr #(
    parameter string INSTANCE_ID = ""
) (
    input wire clk,
    input wire reset,

    // Inputs
    VX_dcr_write_if.slave   dcr_write_if,

    // Output
    output rop_dcrs_t       rop_dcrs
);

    `UNUSED_VAR (reset)

`define DEPTH_TEST_ENABLE(func, writemask) \
        ~((func == `ROP_DEPTH_FUNC_ALWAYS) && ~writemask)
    
`define STENCIL_TEST_ENABLE(func, zpass, zfail) \
         ~((func  == `ROP_DEPTH_FUNC_ALWAYS) \
        && (zpass == `ROP_STENCIL_OP_KEEP)   \
        && (zfail == `ROP_STENCIL_OP_KEEP))

`define BLEND_ENABLE(mode_rgb, mode_a, src_rgb, src_a, dst_rgb, dst_a) \
         ~((mode_rgb == `ROP_BLEND_MODE_ADD)  \
        && (mode_a   == `ROP_BLEND_MODE_ADD)  \
        && (src_rgb  == `ROP_BLEND_FUNC_ONE)  \
        && (src_a    == `ROP_BLEND_FUNC_ONE)  \
        && (dst_rgb  == `ROP_BLEND_FUNC_ZERO) \
        && (dst_a    == `ROP_BLEND_FUNC_ZERO))

    rop_dcrs_t dcrs;

    // DCRs write

    always @(posedge clk) begin
        if (dcr_write_if.valid) begin
            case (dcr_write_if.addr)                
                `DCR_ROP_CBUF_ADDR: begin 
                    dcrs.cbuf_addr <= dcr_write_if.data[31:0];
                end
                `DCR_ROP_CBUF_PITCH: begin 
                    dcrs.cbuf_pitch <= dcr_write_if.data[`ROP_PITCH_BITS-1:0];
                end
                `DCR_ROP_CBUF_WRITEMASK: begin 
                    dcrs.cbuf_writemask <= dcr_write_if.data[3:0];
                end
                `DCR_ROP_ZBUF_ADDR: begin 
                    dcrs.zbuf_addr <= dcr_write_if.data[31:0];
                end
                `DCR_ROP_ZBUF_PITCH: begin 
                    dcrs.zbuf_pitch <= dcr_write_if.data[`ROP_PITCH_BITS-1:0];
                end
                `DCR_ROP_DEPTH_FUNC: begin 
                    dcrs.depth_func   <= dcr_write_if.data[0 +: `ROP_DEPTH_FUNC_BITS];
                    dcrs.depth_enable <= `DEPTH_TEST_ENABLE(dcr_write_if.data[0 +: `ROP_DEPTH_FUNC_BITS], dcrs.depth_writemask);
                end
                `DCR_ROP_DEPTH_WRITEMASK: begin 
                    dcrs.depth_writemask <= dcr_write_if.data[0];
                    dcrs.depth_enable    <= `DEPTH_TEST_ENABLE(dcrs.depth_func, dcr_write_if.data[0]);
                end
                `DCR_ROP_STENCIL_FUNC: begin 
                    dcrs.stencil_func[0]   <= dcr_write_if.data[0 +: `ROP_DEPTH_FUNC_BITS];
                    dcrs.stencil_func[1]   <= dcr_write_if.data[16 +: `ROP_DEPTH_FUNC_BITS];
                    dcrs.stencil_enable[0] <= `STENCIL_TEST_ENABLE(dcr_write_if.data[0 +: `ROP_DEPTH_FUNC_BITS], dcrs.stencil_zpass[0], dcrs.stencil_zfail[0]);
                    dcrs.stencil_enable[1] <= `STENCIL_TEST_ENABLE(dcr_write_if.data[16 +: `ROP_DEPTH_FUNC_BITS], dcrs.stencil_zpass[1], dcrs.stencil_zfail[1]);
                end
                `DCR_ROP_STENCIL_ZPASS: begin 
                    dcrs.stencil_zpass[0]  <= dcr_write_if.data[0 +: `ROP_STENCIL_OP_BITS];
                    dcrs.stencil_zpass[1]  <= dcr_write_if.data[16 +: `ROP_STENCIL_OP_BITS];
                    dcrs.stencil_enable[0] <= `STENCIL_TEST_ENABLE(dcrs.stencil_func[0], dcr_write_if.data[0 +: `ROP_STENCIL_OP_BITS], dcrs.stencil_zfail[0]);
                    dcrs.stencil_enable[1] <= `STENCIL_TEST_ENABLE(dcrs.stencil_func[1], dcr_write_if.data[16 +: `ROP_STENCIL_OP_BITS], dcrs.stencil_zfail[1]);
                end
                `DCR_ROP_STENCIL_ZFAIL: begin 
                    dcrs.stencil_zfail[0]  <= dcr_write_if.data[0 +: `ROP_STENCIL_OP_BITS];
                    dcrs.stencil_zfail[1]  <= dcr_write_if.data[16 +: `ROP_STENCIL_OP_BITS];
                    dcrs.stencil_enable[0] <= `STENCIL_TEST_ENABLE(dcrs.stencil_func[0], dcrs.stencil_zpass[0], dcr_write_if.data[0 +: `ROP_STENCIL_OP_BITS]);
                    dcrs.stencil_enable[1] <= `STENCIL_TEST_ENABLE(dcrs.stencil_func[1], dcrs.stencil_zpass[1], dcr_write_if.data[16 +: `ROP_STENCIL_OP_BITS]);
                end
                `DCR_ROP_STENCIL_FAIL: begin 
                    dcrs.stencil_fail[0] <= dcr_write_if.data[0 +: `ROP_STENCIL_OP_BITS];
                    dcrs.stencil_fail[1] <= dcr_write_if.data[16 +: `ROP_STENCIL_OP_BITS];
                end                
                `DCR_ROP_STENCIL_REF: begin 
                    dcrs.stencil_ref[0] <= dcr_write_if.data[0 +: `ROP_STENCIL_BITS];
                    dcrs.stencil_ref[1] <= dcr_write_if.data[16 +: `ROP_STENCIL_BITS];
                end
                `DCR_ROP_STENCIL_MASK: begin 
                    dcrs.stencil_mask[0] <= dcr_write_if.data[0 +: `ROP_STENCIL_BITS];
                    dcrs.stencil_mask[1] <= dcr_write_if.data[16 +: `ROP_STENCIL_BITS];
                end
                `DCR_ROP_STENCIL_WRITEMASK: begin 
                    dcrs.stencil_writemask[0] <= dcr_write_if.data[0 +: `ROP_STENCIL_BITS];
                    dcrs.stencil_writemask[1] <= dcr_write_if.data[16 +: `ROP_STENCIL_BITS];
                end
                `DCR_ROP_BLEND_MODE: begin 
                    dcrs.blend_mode_rgb <= dcr_write_if.data[0  +: `ROP_BLEND_MODE_BITS];
                    dcrs.blend_mode_a   <= dcr_write_if.data[16 +: `ROP_BLEND_MODE_BITS];
                    dcrs.blend_enable   <= `BLEND_ENABLE(dcr_write_if.data[0  +: `ROP_BLEND_MODE_BITS], dcr_write_if.data[16 +: `ROP_BLEND_MODE_BITS], dcrs.blend_src_rgb, dcrs.blend_src_a, dcrs.blend_dst_rgb, dcrs.blend_dst_a);
                end
                `DCR_ROP_BLEND_FUNC: begin 
                    dcrs.blend_src_rgb <= dcr_write_if.data[0  +: `ROP_BLEND_FUNC_BITS];
                    dcrs.blend_src_a   <= dcr_write_if.data[8  +: `ROP_BLEND_FUNC_BITS];
                    dcrs.blend_dst_rgb <= dcr_write_if.data[16 +: `ROP_BLEND_FUNC_BITS];
                    dcrs.blend_dst_a   <= dcr_write_if.data[24 +: `ROP_BLEND_FUNC_BITS];
                    dcrs.blend_enable  <= `BLEND_ENABLE(dcrs.blend_mode_rgb, dcrs.blend_mode_a, dcr_write_if.data[0 +: `ROP_BLEND_FUNC_BITS], dcr_write_if.data[8 +: `ROP_BLEND_FUNC_BITS], dcr_write_if.data[16 +: `ROP_BLEND_FUNC_BITS], dcr_write_if.data[24 +: `ROP_BLEND_FUNC_BITS]);
                end
                `DCR_ROP_BLEND_CONST: begin 
                    dcrs.blend_const <= dcr_write_if.data[0 +: 32];
                end
                `DCR_ROP_LOGIC_OP: begin
                    dcrs.logic_op <= dcr_write_if.data[0 +: `ROP_LOGIC_OP_BITS];
                end
            endcase
        end
    end

    // DCRs read
    assign rop_dcrs = dcrs;

`ifdef DBG_TRACE_ROP
    always @(posedge clk) begin
        if (dcr_write_if.valid) begin
            `TRACE(1, ("%d: %s-rop-dcr: state=", $time, INSTANCE_ID));
            trace_rop_state(1, dcr_write_if.addr);
            `TRACE(1, (", data=0x%0h\n", dcr_write_if.data));
        end
    end
`endif

endmodule
