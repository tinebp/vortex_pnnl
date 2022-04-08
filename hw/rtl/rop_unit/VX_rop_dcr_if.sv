`include "VX_rop_define.vh"

import VX_rop_types::*;

interface VX_rop_dcr_if ();

    rop_dcrs_t data;

    modport master (
        output data
    );

    modport slave (
        input data
    );

endinterface
