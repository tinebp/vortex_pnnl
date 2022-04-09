`include "VX_platform.vh"

module VX_core_rsp_merge #(
    // Number of Word requests per cycle
    parameter NUM_REQS      = 1, 
    // Number of banks
    parameter NUM_BANKS     = 1, 
    // Number of ports per banks
    parameter NUM_PORTS     = 1,
    // Size of a word in bytes
    parameter WORD_SIZE     = 1, 
    // core request tag size
    parameter TAG_WIDTH     = 1,
    // output register
    parameter OUT_REG       = 0,

    localparam WORD_WIDTH   = WORD_SIZE * 8,
    localparam REQ_SEL_BITS = `CLOG2(NUM_REQS)
) (
    input wire clk,
    input wire reset,

    // Per Bank WB
    input  wire [NUM_BANKS-1:0]                     per_bank_core_rsp_valid,
    input  wire [NUM_BANKS-1:0][NUM_PORTS-1:0]      per_bank_core_rsp_pmask,
    input  wire [NUM_BANKS-1:0][NUM_PORTS-1:0][WORD_WIDTH-1:0] per_bank_core_rsp_data,
    input  wire [NUM_BANKS-1:0][NUM_PORTS-1:0][`UP(REQ_SEL_BITS)-1:0] per_bank_core_rsp_idx,   
    input  wire [NUM_BANKS-1:0][NUM_PORTS-1:0][TAG_WIDTH-1:0] per_bank_core_rsp_tag,   
    output wire [NUM_BANKS-1:0]                     per_bank_core_rsp_ready,

    // Core Response
    output wire [NUM_REQS-1:0]                  core_rsp_valid,
    output wire [NUM_REQS-1:0][TAG_WIDTH-1:0]   core_rsp_tag,
    output wire [NUM_REQS-1:0][WORD_WIDTH-1:0]  core_rsp_data,      
    input  wire [NUM_REQS-1:0]                  core_rsp_ready
);
    localparam BANK_SEL_BITS = `CLOG2(NUM_BANKS);
    localparam PORTS_BITS    = `CLOG2(NUM_PORTS);

    if (NUM_BANKS > 1) begin

        reg [NUM_REQS-1:0] core_rsp_valid_unqual;
        reg [NUM_REQS-1:0][WORD_WIDTH-1:0] core_rsp_data_unqual;
        reg [NUM_BANKS-1:0] per_bank_core_rsp_ready_r;
                
        reg [NUM_REQS-1:0][TAG_WIDTH-1:0] core_rsp_tag_unqual;
        wire [NUM_REQS-1:0] core_rsp_ready_unqual;

        if (NUM_PORTS > 1) begin

            always @(*) begin
                core_rsp_valid_unqual     = '0;
                core_rsp_tag_unqual       = 'x;
                core_rsp_data_unqual      = 'x;
                per_bank_core_rsp_ready_r = '0;
                
                for (integer i = 0; i < NUM_REQS; ++i) begin
                    for (integer j = 0; j < NUM_BANKS * NUM_PORTS; ++j) begin                        
                        bit [PORTS_BITS-1:0]    p = j[0 +: PORTS_BITS];
                        bit [BANK_SEL_BITS-1:0] b = j[PORTS_BITS +: BANK_SEL_BITS];
                        if (per_bank_core_rsp_valid[b] 
                         && per_bank_core_rsp_pmask[b][p] 
                         && per_bank_core_rsp_idx[b][p] == REQ_SEL_BITS'(i)) begin
                            core_rsp_valid_unqual[i] = 1;
                            core_rsp_tag_unqual[i]   = per_bank_core_rsp_tag[b][p];
                            core_rsp_data_unqual[i]  = per_bank_core_rsp_data[b][p];
                            per_bank_core_rsp_ready_r[b] = core_rsp_ready_unqual[i];
                            break;
                        end
                    end
                end    
            end
            
        end else begin
            
            `UNUSED_VAR (per_bank_core_rsp_pmask)

            always @(*) begin
                core_rsp_valid_unqual     = '0;
                core_rsp_tag_unqual       = 'x;
                core_rsp_data_unqual      = 'x;
                per_bank_core_rsp_ready_r = '0;
                
                for (integer i = 0; i < NUM_REQS; ++i) begin
                    for (integer j = 0; j < NUM_BANKS; ++j) begin
                        if (per_bank_core_rsp_valid[j] 
                         && per_bank_core_rsp_idx[j] == REQ_SEL_BITS'(i)) begin
                            core_rsp_valid_unqual[i] = 1;
                            core_rsp_tag_unqual[i]   = per_bank_core_rsp_tag[j];
                            core_rsp_data_unqual[i]  = per_bank_core_rsp_data[j];
                            per_bank_core_rsp_ready_r[j] = core_rsp_ready_unqual[i];
                            break;
                        end
                    end
                end    
            end
        end

        for (genvar i = 0; i < NUM_REQS; i++) begin
            VX_skid_buffer #(
                .DATAW    (TAG_WIDTH + WORD_WIDTH),
                .PASSTHRU (0 == OUT_REG)
            ) out_sbuf (
                .clk       (clk),
                .reset     (reset),
                .valid_in  (core_rsp_valid_unqual[i]),
                .data_in   ({core_rsp_tag_unqual[i], core_rsp_data_unqual[i]}),
                .ready_in  (core_rsp_ready_unqual[i]),
                .valid_out (core_rsp_valid[i]),
                .data_out  ({core_rsp_tag[i],core_rsp_data[i]}),
                .ready_out (core_rsp_ready[i])
            );
        end

        assign per_bank_core_rsp_ready = per_bank_core_rsp_ready_r;

    end else begin

        `UNUSED_VAR (clk)
        `UNUSED_VAR (reset)
        `UNUSED_VAR (per_bank_core_rsp_pmask)

        if (NUM_REQS > 1) begin

            reg [NUM_REQS-1:0][TAG_WIDTH-1:0] core_rsp_tag_unqual;
            reg [NUM_REQS-1:0][WORD_WIDTH-1:0] core_rsp_data_unqual;

            reg [NUM_REQS-1:0] core_rsp_valid_unqual;

            always @(*) begin
                core_rsp_valid_unqual = 0;
                core_rsp_valid_unqual[per_bank_core_rsp_idx] = per_bank_core_rsp_valid;

                core_rsp_tag_unqual = 'x;
                core_rsp_tag_unqual[per_bank_core_rsp_idx] = per_bank_core_rsp_tag;

                core_rsp_data_unqual = 'x;
                core_rsp_data_unqual[per_bank_core_rsp_idx] = per_bank_core_rsp_data;
            end 

            assign core_rsp_valid = core_rsp_valid_unqual;
            assign per_bank_core_rsp_ready = core_rsp_ready[per_bank_core_rsp_idx];

            assign core_rsp_tag   = core_rsp_tag_unqual;
            assign core_rsp_data  = core_rsp_data_unqual;            
            
        end else begin

            `UNUSED_VAR (per_bank_core_rsp_idx)
            assign core_rsp_valid = per_bank_core_rsp_valid;
            assign core_rsp_tag   = per_bank_core_rsp_tag;
            assign core_rsp_data  = per_bank_core_rsp_data;
            assign per_bank_core_rsp_ready = core_rsp_ready;

        end        
    end

endmodule
