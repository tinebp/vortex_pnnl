`include "VX_raster_define.vh"

import VX_raster_types::*;

module VX_raster_req_arb #(
    parameter NUM_REQS = 1
) (
    input wire clk,
    input wire reset,

    // input requests    
    VX_raster_req_if.slave     req_in[NUM_REQS],

    // output request
    VX_raster_req_if.master    req_out
);
    `UNUSED_VAR (clk)
    `UNUSED_VAR (reset)

    // TODO
    for (genvar i = 0; i < NUM_REQS; ++i) begin
        wire valid = req_in[i].valid;
        `UNUSED_VAR (valid)
        assign req_in[i].stamp = '0;
        assign req_in[i].empty = '0;
        assign req_in[i].ready = 0;
    end

    // TODO
    assign req_out.valid = 0;
    `UNUSED_VAR (req_out.stamp)
    `UNUSED_VAR (req_out.empty)
    `UNUSED_VAR (req_out.ready)

endmodule