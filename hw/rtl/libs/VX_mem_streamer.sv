`include "VX_platform.vh"

`TRACING_OFF
module VX_mem_streamer #(
  parameter NUM_REQS = 4,
    parameter ADDRW = 32,	
    parameter DATAW = 32,
    parameter TAGW = 32,
    parameter WORD_SIZE = 4,
    parameter QUEUE_SIZE = 16,
    parameter QUEUE_ADDRW = `CLOG2(QUEUE_SIZE),
    parameter PARTIAL_RESPONSE = 1
) (
    input  wire clk,
    input  wire reset,

    // Input request
    input wire 								req_valid,
    input wire 								req_rw,
    input wire [NUM_REQS-1:0] 				req_mask,
    input wire [WORD_SIZE-1:0] 				req_byteen,
    input wire [NUM_REQS-1:0][ADDRW-1:0] 	req_addr,
    input wire [NUM_REQS-1:0][DATAW-1:0] 	req_data,
    input wire [TAGW-1:0]					req_tag,
    output wire 							req_ready,

    // Output request
    output wire [NUM_REQS-1:0] 					mem_req_valid,
    output wire [NUM_REQS-1:0] 					mem_req_rw,
    output wire [NUM_REQS-1:0][WORD_SIZE-1:0] 	mem_req_byteen,
    output wire [NUM_REQS-1:0][ADDRW-1:0] 		mem_req_addr,
    output wire [NUM_REQS-1:0][DATAW-1:0] 		mem_req_data,
    output wire [NUM_REQS-1:0][QUEUE_ADDRW-1:0] mem_req_tag,
    input wire 	[NUM_REQS-1:0]					mem_req_ready,

    // Input response
    input wire 								mem_rsp_valid,
    input wire [NUM_REQS-1:0] 				mem_rsp_mask,
    input wire [NUM_REQS-1:0][DATAW-1:0] 	mem_rsp_data,
    input wire [QUEUE_ADDRW-1:0] 			mem_rsp_tag,
    output wire 							mem_rsp_ready,

    // Output response
    output wire 							rsp_valid,
    output wire [NUM_REQS-1:0] 				rsp_mask,
    output wire [NUM_REQS-1:0][DATAW-1:0] 	rsp_data,
    output wire [TAGW-1:0] 					rsp_tag,
    input wire 								rsp_ready
  );

    localparam RSPW = TAGW + NUM_REQS + (NUM_REQS * DATAW) + 1;

    // Detect duplicate addresses
    wire [NUM_REQS-2:0] addr_matches;
    wire req_dup;
    wire [NUM_REQS-1:0] req_dup_mask;

    // Pending queue
    wire 								pq_rw;
    wire [NUM_REQS-1:0] 				pq_mask;
    wire [WORD_SIZE-1:0] 				pq_byteen;
    wire [NUM_REQS-1:0][ADDRW-1:0] 		pq_addr;
    wire [NUM_REQS-1:0][DATAW-1:0] 		pq_data;
    wire [QUEUE_ADDRW-1:0] 				pq_tag;

    wire	sreq_push;
    wire 	sreq_pop;
    wire 	sreq_full;
    wire 	sreq_empty;

    wire 					stag_push;
    wire  					stag_pop;
    wire [QUEUE_ADDRW-1:0] 	stag_waddr;
    wire [QUEUE_ADDRW-1:0] 	stag_raddr;
    wire 					stag_full;
    wire 					stag_empty;

    // Memory request
    wire 									mreq_en;	
    wire [NUM_REQS-1:0] 					mreq_valid;
    wire [NUM_REQS-1:0] 					mreq_rw;
    wire [NUM_REQS-1:0][WORD_SIZE-1:0] 		mreq_byteen;
    wire [NUM_REQS-1:0][ADDRW-1:0] 			mreq_addr;
    wire [NUM_REQS-1:0][DATAW-1:0] 			mreq_data;
    wire [NUM_REQS-1:0][QUEUE_ADDRW-1:0] 	mreq_tag;

    wire [NUM_REQS-1:0] mem_req_fire;
    reg  [NUM_REQS-1:0] req_sent_mask;
    wire [NUM_REQS-1:0] req_sent_mask_n;
    wire 				req_sent_all;

    // Memory response
    reg  [QUEUE_SIZE-1:0][RSPW-1:0]			rsp;
    wire [RSPW-1:0] 						rsp_in;
    reg  [RSPW-1:0] 						rsp_out;
    wire 									mem_rsp_fire;
    reg  [QUEUE_SIZE-1:0][NUM_REQS-1:0]		rsp_rem_mask;
    wire [NUM_REQS-1:0] 					rsp_rem_mask_n;

    //////////////////////////////////////////////////////////////////

    // Detect duplicate addresses

    for(genvar i = 0; i < NUM_REQS-1; i++) begin
        assign addr_matches[i] = (req_addr[i+1] == req_addr[0]) || ~req_mask[i+1];
    end

    assign req_dup = req_mask[0] && (& addr_matches);
    assign req_dup_mask = req_mask & {{(NUM_REQS-1){~req_dup}}, 1'b1};

    //////////////////////////////////////////////////////////////////

    // Save incoming requests into a pending queue

    assign sreq_push 		= req_valid && !sreq_full && !stag_full;
    assign sreq_pop 		= req_sent_all && !sreq_empty;
    assign req_ready 		= !sreq_full && !stag_full;

    VX_fifo_queue #(
        .DATAW	(1 + NUM_REQS + WORD_SIZE + (NUM_REQS * ADDRW) + (NUM_REQS * DATAW) + QUEUE_ADDRW),
        .SIZE	(QUEUE_SIZE)
    ) store_req (
        .clk		(clk),
        .reset		(reset),
        .push		(sreq_push),
        .pop		(sreq_pop),
        .data_in	({req_rw, req_dup_mask, req_byteen, req_addr, req_data, stag_waddr}),
        .data_out	({pq_rw,  pq_mask,      pq_byteen,  pq_addr,  pq_data, pq_tag}),
        .full		(sreq_full),
        .empty 		(sreq_empty),
        `UNUSED_PIN (alm_full),
        `UNUSED_PIN (alm_empty),
        `UNUSED_PIN (size)
    );

    assign stag_push = sreq_push;
    assign stag_pop = mem_rsp_fire && (0 == rsp_rem_mask_n) && !stag_empty;
    assign stag_raddr = mem_rsp_tag;
    wire [TAGW-1:0] mrsp_tag;

    VX_index_buffer #(
        .DATAW	(TAGW),
        .SIZE	(QUEUE_SIZE)
    ) store_tag (
        .clk			(clk),
        .reset			(reset),
        .write_addr		(stag_waddr),
        .acquire_slot	(stag_push),
        .read_addr		(stag_raddr),
        .write_data		(req_tag),
        .read_data		(mrsp_tag),
        .release_addr	(stag_raddr),
        .release_slot	(stag_pop),
        .full			(stag_full),
        .empty			(stag_empty)
    );

    //////////////////////////////////////////////////////////////////

    // Memory response
    assign mem_rsp_ready = 1'b1;
    assign mem_rsp_fire = mem_rsp_valid && mem_rsp_ready;

    // Evaluate remaning responses
    assign rsp_rem_mask_n = rsp_rem_mask[stag_raddr] & ~mem_rsp_mask;

    always @(posedge clk) begin
        if (sreq_push) 
            rsp_rem_mask[stag_waddr] <= req_dup_mask;
        if (mem_rsp_fire)
            rsp_rem_mask[stag_raddr] <= rsp_rem_mask_n;
    end

    // Store response till ready to send
    assign rsp_in = rsp[stag_raddr] | {mrsp_tag, mem_rsp_mask, mem_rsp_data, mem_rsp_valid};

    always @(posedge clk) begin
        rsp_out <= 0;
        if (reset)
            rsp <= 0;
        if (sreq_push)
            rsp[stag_waddr] <= 0;
        if(mem_rsp_fire) begin
            rsp[stag_raddr] <= rsp_in;
            if ((PARTIAL_RESPONSE || (0 == rsp_rem_mask_n)) && rsp_in[0] && rsp_ready)
                rsp_out <= rsp_in;
        end
    end

    // Send response
    VX_pipe_register #(
        .DATAW	(RSPW),
        .RESETW (1)
    ) rsp_pipe_reg (
        .clk		(clk),
        .reset		(reset),
        .enable		(1'b1),
        .data_in	({rsp_out}),
        .data_out	({rsp_tag, rsp_mask, rsp_data, rsp_valid})
    );

    //////////////////////////////////////////////////////////////////

    // Memory request
    assign mreq_valid 	= pq_mask & ~req_sent_mask & {NUM_REQS{!sreq_empty}};
    assign mreq_rw 	    = {NUM_REQS{pq_rw}};
    assign mreq_byteen  = {NUM_REQS{pq_byteen}};
    assign mreq_addr 	= pq_addr;
    assign mreq_data 	= pq_data;
    assign mreq_tag 	= {NUM_REQS{pq_tag}};
    assign mreq_en 		= 1'b1;

    assign mem_req_fire 	= mreq_valid & mem_req_ready;
    assign req_sent_mask_n 	= req_sent_mask | mem_req_fire;
    assign req_sent_all 	= (req_sent_mask_n == pq_mask);

    always @(posedge clk) begin
        if (reset)
            req_sent_mask <= 0;
        else begin
            if (req_sent_all)
                req_sent_mask <= 0;
            else
                req_sent_mask <= req_sent_mask_n;
        end
    end

    VX_pipe_register #(
        .DATAW	(NUM_REQS + NUM_REQS + (NUM_REQS * WORD_SIZE) + (NUM_REQS * ADDRW) + (NUM_REQS * DATAW) + (NUM_REQS * QUEUE_ADDRW)),
        .RESETW (1)
    ) req_pipe_reg (
        .clk		(clk),
        .reset		(reset),
        .enable		(mreq_en),
        .data_in	({mreq_valid,    mreq_rw,    mreq_byteen,    mreq_addr,    mreq_data,    mreq_tag}),
        .data_out	({mem_req_valid, mem_req_rw, mem_req_byteen, mem_req_addr, mem_req_data, mem_req_tag})
    );

    //////////////////////////////////////////////////////////////////

    // Debugging

    always @(posedge clk) begin
        // $display ("MSU: already_sent: %b", already_sent);
    end

endmodule
`TRACING_ON