`include "VX_platform.vh"

`TRACING_OFF
module VX_axi_adapter #(
    parameter DATA_WIDTH     = 512, 
    parameter ADDR_WIDTH     = 32,
    parameter TAG_WIDTH      = 8,
    parameter AVS_ADDR_WIDTH = (ADDR_WIDTH - $clog2(DATA_WIDTH/8))
) (
    input  wire                     clk,
    input  wire                     reset,

    // Vortex request
    input wire                      mem_req_valid,
    input wire                      mem_req_rw,
    input wire [DATA_WIDTH/8-1:0]   mem_req_byteen,
    input wire [AVS_ADDR_WIDTH-1:0] mem_req_addr,
    input wire [DATA_WIDTH-1:0]     mem_req_data,
    input wire [TAG_WIDTH-1:0]      mem_req_tag,

    // Vortex response
    input wire                      mem_rsp_ready,
    output wire                     mem_rsp_valid,        
    output wire [DATA_WIDTH-1:0]    mem_rsp_data,
    output wire [TAG_WIDTH-1:0]     mem_rsp_tag,
    output wire                     mem_req_ready,

    // AXI write request address channel  
    output wire                     m_axi_awvalid,
    input wire                      m_axi_awready,
    output wire [ADDR_WIDTH-1:0]    m_axi_awaddr,
    output wire [TAG_WIDTH-1:0]     m_axi_awid,
    output wire [7:0]               m_axi_awlen,
    output wire [2:0]               m_axi_awsize,
    output wire [1:0]               m_axi_awburst,
    output wire [1:0]               m_axi_awlock,    
    output wire [3:0]               m_axi_awcache,
    output wire [2:0]               m_axi_awprot,        
    output wire [3:0]               m_axi_awqos,
    output wire [3:0]               m_axi_awregion,

    // AXI write request data channel   
    output wire                     m_axi_wvalid, 
    input wire                      m_axi_wready,  
    output wire [DATA_WIDTH-1:0]    m_axi_wdata,
    output wire [DATA_WIDTH/8-1:0]  m_axi_wstrb,
    output wire                     m_axi_wlast,

    // AXI write response channel
    input wire                      m_axi_bvalid,
    output wire                     m_axi_bready,
    input wire [TAG_WIDTH-1:0]      m_axi_bid,
    input wire [1:0]                m_axi_bresp,
    
    // AXI read address channel
    output wire                     m_axi_arvalid,
    input wire                      m_axi_arready,
    output wire [ADDR_WIDTH-1:0]    m_axi_araddr,
    output wire [TAG_WIDTH-1:0]     m_axi_arid,
    output wire [7:0]               m_axi_arlen,
    output wire [2:0]               m_axi_arsize,
    output wire [1:0]               m_axi_arburst,    
    output wire [1:0]               m_axi_arlock,    
    output wire [3:0]               m_axi_arcache,
    output wire [2:0]               m_axi_arprot,        
    output wire [3:0]               m_axi_arqos, 
    output wire [3:0]               m_axi_arregion,
    
    // AXI read response channel
    input wire                      m_axi_rvalid,
    output wire                     m_axi_rready,
    input wire [DATA_WIDTH-1:0]     m_axi_rdata,
    input wire                      m_axi_rlast,
    input wire [TAG_WIDTH-1:0]      m_axi_rid,
    input wire [1:0]                m_axi_rresp
);  
    localparam AXSIZE = $clog2(DATA_WIDTH/8);    

    wire mem_req_fire  = mem_req_valid && mem_req_ready;
    wire m_axi_aw_fire = m_axi_awvalid && m_axi_awready;
    wire m_axi_w_fire  = m_axi_wvalid && m_axi_wready;

    reg m_axi_aw_ack;
    reg m_axi_w_ack;
    
    always @(posedge clk) begin
		if (reset) begin
			m_axi_aw_ack <= 0;
            m_axi_w_ack  <= 0;
		end else begin			
            if (mem_req_fire) begin
                m_axi_aw_ack <= 0;
                m_axi_w_ack  <= 0;
            end else begin
                if (m_axi_aw_fire)
                    m_axi_aw_ack <= 1;
                if (m_axi_w_fire)
                    m_axi_w_ack <= 1;
            end
		end
	end

    // Vortex request ack	
    wire axi_write_ready = (m_axi_awready || m_axi_aw_ack) && (m_axi_wready || m_axi_w_ack);
    assign mem_req_ready = mem_req_rw ? axi_write_ready : m_axi_arready;

    // AXI write request address channel        
    assign m_axi_awvalid    = mem_req_valid && mem_req_rw && ~m_axi_aw_ack;    
    assign m_axi_awaddr     = ADDR_WIDTH'(mem_req_addr) << AXSIZE;
    assign m_axi_awid       = mem_req_tag;
    assign m_axi_awlen      = 8'b00000000;    
    assign m_axi_awsize     = 3'(AXSIZE);
    assign m_axi_awburst    = 2'b00;    
    assign m_axi_awlock     = 2'b00;    
    assign m_axi_awcache    = 4'b0000;
    assign m_axi_awprot     = 3'b000;    
    assign m_axi_awqos      = 4'b0000;
    assign m_axi_awregion   = 4'b0000;

    // AXI write request data channel        
    assign m_axi_wvalid     = mem_req_valid && mem_req_rw && ~m_axi_w_ack;
    assign m_axi_wdata      = mem_req_data;
    assign m_axi_wstrb      = mem_req_byteen;
    assign m_axi_wlast      = 1'b1;

    // AXI write response channel (ignore)
    `UNUSED_VAR (m_axi_bvalid)
    `UNUSED_VAR (m_axi_bid)
    `UNUSED_VAR (m_axi_bresp)
    assign m_axi_bready     = 1'b1;
    `RUNTIME_ASSERT(~m_axi_bvalid || m_axi_bresp == 0, ("%t: *** AXI response error", $time));    

    // AXI read request channel
    assign m_axi_arvalid    = mem_req_valid && ~mem_req_rw;    
    assign m_axi_araddr     = ADDR_WIDTH'(mem_req_addr) << AXSIZE;
    assign m_axi_arid       = mem_req_tag;
    assign m_axi_arlen      = 8'b00000000;
    assign m_axi_arsize     = 3'(AXSIZE);
    assign m_axi_arburst    = 2'b00;  
    assign m_axi_arlock     = 2'b00;    
    assign m_axi_arcache    = 4'b0000;
    assign m_axi_arprot     = 3'b000;
    assign m_axi_arqos      = 4'b0000;
    assign m_axi_arregion   = 4'b0000;

    // AXI read response channel    
    assign mem_rsp_valid    = m_axi_rvalid;
    assign mem_rsp_tag      = m_axi_rid;
    assign mem_rsp_data     = m_axi_rdata;
    `UNUSED_VAR (m_axi_rlast)    
    assign m_axi_rready     = mem_rsp_ready;
    `RUNTIME_ASSERT(~m_axi_rvalid || m_axi_rlast == 1, ("%t: *** AXI response error", $time));
    `RUNTIME_ASSERT(~m_axi_rvalid || m_axi_rresp == 0, ("%t: *** AXI response error", $time));

endmodule
`TRACING_ON
