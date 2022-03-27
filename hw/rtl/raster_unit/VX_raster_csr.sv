`include "VX_raster_define.vh"

module VX_raster_csr #( 
    parameter CORE_ID = 0
) (
    input wire clk,
    input wire reset,

    // Inputs    
    input wire write_enable,
    VX_raster_svc_if.slave raster_svc_req_if,    
    VX_raster_req_if.slave raster_req_if,

    // Output
    VX_gpu_csr_if.slave raster_csr_if
);
    `UNUSED_VAR (reset)

    raster_csrs_t [`NUM_THREADS-1:0] wdata;
    raster_csrs_t [`NUM_THREADS-1:0] rdata;
    wire [`NUM_THREADS-1:0] wren;;
    wire [`NW_BITS-1:0] waddr;
    wire [`NW_BITS-1:0] raddr;

    // CSR registers
    for (genvar i = 0; i < `NUM_THREADS; ++i) begin
        VX_dp_ram #(
            .DATAW       ($bits(raster_csrs_t)),
            .SIZE        (`NUM_WARPS),
            .INIT_ENABLE (1),
            .INIT_VALUE  (0)
        ) dp_ram (
            .clk   (clk),
            .wren  (wren[i]),
            .waddr (waddr),
            .wdata (wdata[i]),
            .raddr (raddr),
            .rdata (rdata[i])
        );
    end

    // CSRs write

    assign wren  = {`NUM_THREADS{write_enable}} & raster_req_if.tmask;
    assign waddr = raster_svc_req_if.wid;

    for (genvar i = 0; i < `NUM_THREADS; ++i) begin
        assign wdata[i].pos_mask = {raster_req_if.stamps[i].pos_y, raster_req_if.stamps[i].pos_x, raster_req_if.stamps[i].mask}; 
        assign wdata[i].bcoord_x = raster_req_if.stamps[i].bcoord_x;
        assign wdata[i].bcoord_y = raster_req_if.stamps[i].bcoord_y;
        assign wdata[i].bcoord_z = raster_req_if.stamps[i].bcoord_z;    
    end
    
    // CSRs read

    assign raddr = raster_csr_if.read_wid;

    reg [`NUM_THREADS-1:0][31:0] read_data_r;
    always @(*) begin
        for (integer i = 0; i < `NUM_THREADS; ++i) begin
            read_data_r[i] = 'x;
            case (raster_csr_if.read_addr)
                `CSR_RASTER_POS_MASK:  read_data_r[i] = rdata[i].pos_mask;
                `CSR_RASTER_BCOORD_X0: read_data_r[i] = rdata[i].bcoord_x[0];
                `CSR_RASTER_BCOORD_X1: read_data_r[i] = rdata[i].bcoord_x[1];
                `CSR_RASTER_BCOORD_X2: read_data_r[i] = rdata[i].bcoord_x[2];
                `CSR_RASTER_BCOORD_Y0: read_data_r[i] = rdata[i].bcoord_y[0];
                `CSR_RASTER_BCOORD_Y1: read_data_r[i] = rdata[i].bcoord_y[1];
                `CSR_RASTER_BCOORD_Y2: read_data_r[i] = rdata[i].bcoord_y[2];
                `CSR_RASTER_BCOORD_Z0: read_data_r[i] = rdata[i].bcoord_z[0];
                `CSR_RASTER_BCOORD_Z1: read_data_r[i] = rdata[i].bcoord_z[1];
                `CSR_RASTER_BCOORD_Z2: read_data_r[i] = rdata[i].bcoord_z[2];
                default:;
            endcase
        end
    end

    assign raster_csr_if.read_data = read_data_r;

    `UNUSED_VAR (raster_csr_if.read_enable)
    `UNUSED_VAR (raster_csr_if.read_uuid)
    `UNUSED_VAR (raster_csr_if.read_tmask)
    `UNUSED_VAR (raster_csr_if.write_uuid)
    `UNUSED_VAR (raster_csr_if.write_wid)
    `UNUSED_VAR (raster_csr_if.write_tmask)

`ifdef DBG_TRACE_TEX
    logic [`NUM_THREADS-1:0][`RASTER_DIM_BITS-2:0] pos_x;
    logic [`NUM_THREADS-1:0][`RASTER_DIM_BITS-2:0] pos_y;
    logic [`NUM_THREADS-1:0][3:0]                  mask;

    for (genvar i = 0; i < `NUM_THREADS; ++i) begin
        assign pos_x[i] = raster_req_if.stamps[i].pos_x;
        assign pos_y[i] = raster_req_if.stamps[i].pos_y;
        assign mask[i]  = raster_req_if.stamps[i].mask;
    end

    always @(posedge clk) begin
        if (raster_csr_if.read_enable) begin
            dpi_trace("%d: core%0d-raster-csr-read: wid=%0d, tmask=%b, state=", $time, CORE_ID, raster_csr_if.read_wid, raster_csr_if.read_tmask);
            trace_raster_csr(raster_csr_if.read_addr);
            dpi_trace(", data=");
            `TRACE_ARRAY1D(raster_csr_if.read_data, `NUM_THREADS);
            dpi_trace(" (#%0d)\n", raster_csr_if.read_uuid);
        end
        if (write_enable) begin
            dpi_trace("%d: core%0d-raster-fetch: wid=%0d, tmask=%b, pos_x=", $time, CORE_ID, raster_svc_req_if.wid, raster_svc_req_if.tmask);
            `TRACE_ARRAY1D(pos_x, `NUM_THREADS);
            dpi_trace(", pos_y=");
            `TRACE_ARRAY1D(pos_y, `NUM_THREADS);
            dpi_trace(", mask=");
            `TRACE_ARRAY1D(mask, `NUM_THREADS);
            dpi_trace(" (#%0d)\n", raster_svc_req_if.uuid);
        end
    end
`endif

endmodule
