`include "VX_define.vh"

module VX_cache_rsp_sel #(
    parameter NUM_REQS      = 1, 
    parameter DATA_WIDTH    = 1, 
    parameter TAG_WIDTH     = 1,    
    parameter TAG_ID_BITS   = 0,
    parameter OUT_REG       = 0
) (
    input wire              clk,
    input wire              reset,

    // input response
    VX_mem_rsp_if.slave     rsp_in_if[NUM_REQS],

    // output responses
    VX_cache_rsp_if.master  rsp_out_if
);
    `UNUSED_VAR (clk)
    `UNUSED_VAR (reset)

    for (genvar i = 0; i < NUM_REQS; ++i) begin
        wire valid = rsp_in_if[i].valid;
        wire [DATA_WIDTH-1:0] data = rsp_in_if[i].data;
        wire [TAG_WIDTH-1:0] tag = rsp_in_if[i].tag;
        `UNUSED_VAR (valid)
        `UNUSED_VAR (data)
        `UNUSED_VAR (tag)
        assign rsp_in_if[i].ready = 0;
    end

    assign rsp_out_if.valid = 0;
    assign rsp_out_if.tmask = '0;
    assign rsp_out_if.data  = '0;
    assign rsp_out_if.tag   = '0;
    `UNUSED_VAR (rsp_out_if.ready)
    /*
    if (NUM_BANKS > 1) begin

        reg [NUM_REQS-1:0] core_rsp_valid_unqual;
        reg [NUM_REQS-1:0][`WORD_WIDTH-1:0] core_rsp_data_unqual;
        reg [NUM_BANKS-1:0] per_bank_core_rsp_ready_r;
                
        if (TAG_ID_BITS != 0) begin

            // The core response bus handles a single tag at the time
            // We first need to select the current tag to process,
            // then send all bank responses for that tag as a batch

            wire [TAG_WIDTH-1:0] core_rsp_tag_unqual;
            wire core_rsp_ready_unqual;

            if (NUM_PORTS > 1) begin

                reg [NUM_BANKS-1:0][NUM_PORTS-1:0] per_bank_core_rsp_sent_r, per_bank_core_rsp_sent;
                wire [NUM_BANKS-1:0][NUM_PORTS-1:0] per_bank_core_rsp_sent_n;

                for (genvar i = 0; i < NUM_BANKS; ++i) begin
                    assign per_bank_core_rsp_sent_n[i] = per_bank_core_rsp_sent_r[i] | per_bank_core_rsp_sent[i];
                end
            
                always @(posedge clk) begin
                    if (reset) begin
                        per_bank_core_rsp_sent_r <= '0;
                    end else begin
                        for (integer i = 0; i < NUM_BANKS; ++i) begin
                            if (per_bank_core_rsp_sent_n[i] == per_bank_core_rsp_pmask[i]) begin
                                per_bank_core_rsp_sent_r[i] <= '0;
                            end else begin 
                                per_bank_core_rsp_sent_r[i] <= per_bank_core_rsp_sent_n[i];
                            end
                        end
                    end
                end

                wire [NUM_BANKS-1:0][NUM_PORTS-1:0] per_bank_core_rsp_valid_p;
                for (genvar i = 0; i < NUM_BANKS; ++i) begin
                    for (genvar p = 0; p < NUM_PORTS; ++p) begin
                        assign per_bank_core_rsp_valid_p[i][p] = per_bank_core_rsp_valid[i] 
                                                              && per_bank_core_rsp_pmask[i][p]
                                                              && !per_bank_core_rsp_sent_r[i][p];
                    end
                end

                VX_find_first #(
                    .N     (NUM_BANKS * NUM_PORTS),
                    .DATAW (TAG_WIDTH)
                ) find_first (
                    .valid_i (per_bank_core_rsp_valid_p),
                    .data_i  (per_bank_core_rsp_tag),
                    .data_o  (core_rsp_tag_unqual),
                    `UNUSED_PIN (valid_o)
                );

                always @(*) begin            
                    core_rsp_valid_unqual  = 0;
                    core_rsp_data_unqual   = 'x; 
                    per_bank_core_rsp_sent = 0;
                    
                    for (integer i = 0; i < NUM_BANKS; ++i) begin
                        for (integer p = 0; p < NUM_PORTS; ++p) begin 
                            if (per_bank_core_rsp_valid[i]                            
                             && per_bank_core_rsp_pmask[i][p]
                             && !per_bank_core_rsp_sent_r[i][p]
                            && (per_bank_core_rsp_tag[i][p][TAG_ID_BITS-1:0] == core_rsp_tag_unqual[TAG_ID_BITS-1:0])) begin
                                core_rsp_valid_unqual[per_bank_core_rsp_tid[i][p]] = 1;
                                core_rsp_data_unqual[per_bank_core_rsp_tid[i][p]]  = per_bank_core_rsp_data[i][p];
                                per_bank_core_rsp_sent[i][p] = core_rsp_ready_unqual;
                            end
                        end
                    end
                end

                always @(*) begin
                    for (integer i = 0; i < NUM_BANKS; ++i) begin
                        per_bank_core_rsp_ready_r[i] = (per_bank_core_rsp_sent_n[i] == per_bank_core_rsp_pmask[i]);
                    end
                end

            end else begin

                `UNUSED_VAR (per_bank_core_rsp_pmask)

                VX_find_first #(
                    .N     (NUM_BANKS),
                    .DATAW (TAG_WIDTH)
                ) find_first (
                    .valid_i (per_bank_core_rsp_valid),
                    .data_i  (per_bank_core_rsp_tag),
                    .data_o  (core_rsp_tag_unqual),
                    `UNUSED_PIN (valid_o)
                );
                
                always @(*) begin                
                    core_rsp_valid_unqual     = 0;
                    core_rsp_data_unqual      = 'x;                
                    per_bank_core_rsp_ready_r = 0;
                    
                    for (integer i = 0; i < NUM_BANKS; i++) begin
                        if (per_bank_core_rsp_valid[i]            
                        && (per_bank_core_rsp_tag[i][0][TAG_ID_BITS-1:0] == core_rsp_tag_unqual[TAG_ID_BITS-1:0])) begin
                            core_rsp_valid_unqual[per_bank_core_rsp_tid[i]] = 1;     
                            core_rsp_data_unqual[per_bank_core_rsp_tid[i]]  = per_bank_core_rsp_data[i];
                            per_bank_core_rsp_ready_r[i] = core_rsp_ready_unqual;
                        end
                    end
                end
            end                            

            wire core_rsp_valid_any = (| per_bank_core_rsp_valid);
            
            VX_skid_buffer #(
                .DATAW    (NUM_REQS + TAG_WIDTH + (NUM_REQS *`WORD_WIDTH)),
                .PASSTHRU (0 == OUT_REG)
            ) out_sbuf (
                .clk       (clk),
                .reset     (reset),
                .valid_in  (core_rsp_valid_any),        
                .data_in   ({core_rsp_valid_unqual, core_rsp_tag_unqual, core_rsp_data_unqual}),
                .ready_in  (core_rsp_ready_unqual),      
                .valid_out (core_rsp_valid),
                .data_out  ({core_rsp_tmask, core_rsp_tag, core_rsp_data}),
                .ready_out (core_rsp_ready)
            );

        end else begin

            reg [NUM_REQS-1:0][TAG_WIDTH-1:0] core_rsp_tag_unqual;
            wire [NUM_REQS-1:0] core_rsp_ready_unqual;

            if (NUM_PORTS > 1) begin

                reg [NUM_REQS-1:0][(`PORTS_BITS + `BANK_SELECT_BITS)-1:0] bank_select_table;

                reg [NUM_BANKS-1:0][NUM_PORTS-1:0] per_bank_core_rsp_sent_r, per_bank_core_rsp_sent;
                wire [NUM_BANKS-1:0][NUM_PORTS-1:0] per_bank_core_rsp_sent_n;

                for (genvar i = 0; i < NUM_BANKS; ++i) begin
                    assign per_bank_core_rsp_sent_n[i] = per_bank_core_rsp_sent_r[i] | per_bank_core_rsp_sent[i];
                end
            
                always @(posedge clk) begin
                    if (reset) begin
                        per_bank_core_rsp_sent_r <= '0;
                    end else begin
                        for (integer i = 0; i < NUM_BANKS; ++i) begin
                            if (per_bank_core_rsp_sent_n[i] == per_bank_core_rsp_pmask[i]) begin
                                per_bank_core_rsp_sent_r[i] <= '0;
                            end else begin 
                                per_bank_core_rsp_sent_r[i] <= per_bank_core_rsp_sent_n[i];
                            end
                        end
                    end
                end               

                always @(*) begin
                    core_rsp_valid_unqual = '0;                
                    core_rsp_tag_unqual   = 'x;
                    core_rsp_data_unqual  = 'x;
                    bank_select_table     = 'x;
                    
                    for (integer i = NUM_BANKS-1; i >= 0; --i) begin
                        for (integer p = 0; p < NUM_PORTS; ++p) begin 
                            if (per_bank_core_rsp_valid[i] 
                             && per_bank_core_rsp_pmask[i][p]
                             && !per_bank_core_rsp_sent_r[i][p]) begin
                                core_rsp_valid_unqual[per_bank_core_rsp_tid[i][p]] = 1;
                                core_rsp_tag_unqual[per_bank_core_rsp_tid[i][p]]   = per_bank_core_rsp_tag[i][p];
                                core_rsp_data_unqual[per_bank_core_rsp_tid[i][p]]  = per_bank_core_rsp_data[i][p];
                                bank_select_table[per_bank_core_rsp_tid[i][p]] = {`PORTS_BITS'(p), `BANK_SELECT_BITS'(i)};                      
                            end
                        end
                    end    
                end

                always @(*) begin
                    per_bank_core_rsp_sent = '0;
                    for (integer i = 0; i < NUM_REQS; i++) begin
                        if (core_rsp_valid_unqual[i]) begin
                            per_bank_core_rsp_sent[bank_select_table[i][0 +: `BANK_SELECT_BITS]][bank_select_table[i][`BANK_SELECT_BITS +: `PORTS_BITS]] = core_rsp_ready_unqual[i];
                        end
                    end
                end

                always @(*) begin
                    for (integer i = 0; i < NUM_BANKS; i++) begin 
                        per_bank_core_rsp_ready_r[i] = (per_bank_core_rsp_sent_n[i] == per_bank_core_rsp_pmask[i]);
                    end    
                end
                
            end else begin    
                
                `UNUSED_VAR (per_bank_core_rsp_pmask)
                reg [NUM_REQS-1:0][NUM_BANKS-1:0] bank_select_table;

                always @(*) begin
                    core_rsp_valid_unqual = 0;                
                    core_rsp_tag_unqual   = 'x;
                    core_rsp_data_unqual  = 'x;
                    bank_select_table     = 'x;
                    
                    for (integer i = NUM_BANKS-1; i >= 0; --i) begin
                        if (per_bank_core_rsp_valid[i]) begin
                            core_rsp_valid_unqual[per_bank_core_rsp_tid[i]] = 1;     
                            core_rsp_tag_unqual[per_bank_core_rsp_tid[i]]   = per_bank_core_rsp_tag[i];
                            core_rsp_data_unqual[per_bank_core_rsp_tid[i]]  = per_bank_core_rsp_data[i];
                            bank_select_table[per_bank_core_rsp_tid[i]]  = (1 << i);
                        end
                    end    
                end

                always @(*) begin
                    for (integer i = 0; i < NUM_BANKS; ++i) begin 
                        per_bank_core_rsp_ready_r[i] = core_rsp_ready_unqual[per_bank_core_rsp_tid[i]] 
                                                    && bank_select_table[per_bank_core_rsp_tid[i]][i];
                    end    
                end                
            end

            for (genvar i = 0; i < NUM_REQS; i++) begin
                VX_skid_buffer #(
                    .DATAW    (TAG_WIDTH + `WORD_WIDTH),
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

            assign core_rsp_tmask = core_rsp_valid;

        end        

        assign per_bank_core_rsp_ready = per_bank_core_rsp_ready_r;

    end else begin

        `UNUSED_VAR (clk)
        `UNUSED_VAR (reset)
        `UNUSED_VAR (per_bank_core_rsp_pmask)

        if (NUM_REQS > 1) begin

            reg [`RSP_TAGS-1:0][TAG_WIDTH-1:0] core_rsp_tag_unqual;
            reg [NUM_REQS-1:0][`WORD_WIDTH-1:0] core_rsp_data_unqual;

            if (TAG_ID_BITS != 0) begin

                reg [NUM_REQS-1:0] core_rsp_tmask_unqual;

                always @(*) begin
                    core_rsp_tmask_unqual = 0; 
                    core_rsp_tmask_unqual[per_bank_core_rsp_tid] = per_bank_core_rsp_valid;

                    core_rsp_tag_unqual = per_bank_core_rsp_tag;

                    core_rsp_data_unqual = 'x;                    
                    core_rsp_data_unqual[per_bank_core_rsp_tid] = per_bank_core_rsp_data;  
                end           

                assign core_rsp_valid = per_bank_core_rsp_valid;
                assign core_rsp_tmask = core_rsp_tmask_unqual;
                assign per_bank_core_rsp_ready = core_rsp_ready;
                    
            end else begin

                reg [`RSP_TAGS-1:0] core_rsp_valid_unqual;

                always @(*) begin
                    core_rsp_valid_unqual = 0;                
                    core_rsp_valid_unqual[per_bank_core_rsp_tid] = per_bank_core_rsp_valid;

                    core_rsp_tag_unqual = 'x;                    
                    core_rsp_tag_unqual[per_bank_core_rsp_tid] = per_bank_core_rsp_tag;

                    core_rsp_data_unqual = 'x;                    
                    core_rsp_data_unqual[per_bank_core_rsp_tid] = per_bank_core_rsp_data;  
                end 

                assign core_rsp_valid = core_rsp_valid_unqual;
                assign core_rsp_tmask = core_rsp_valid_unqual;
                assign per_bank_core_rsp_ready = core_rsp_ready[per_bank_core_rsp_tid];

            end

            assign core_rsp_tag   = core_rsp_tag_unqual;
            assign core_rsp_data  = core_rsp_data_unqual;            
            
        end else begin

            `UNUSED_VAR(per_bank_core_rsp_tid)
            assign core_rsp_valid = per_bank_core_rsp_valid;
            assign core_rsp_tmask = per_bank_core_rsp_valid;
            assign core_rsp_tag   = per_bank_core_rsp_tag;
            assign core_rsp_data  = per_bank_core_rsp_data;
            assign per_bank_core_rsp_ready = core_rsp_ready;

        end        
    end*/

endmodule
