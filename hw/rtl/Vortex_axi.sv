`include "VX_define.vh"
`include "VX_gpu_types.vh"

`IGNORE_WARNINGS_BEGIN
import VX_gpu_types::*;
`IGNORE_WARNINGS_END

module Vortex_axi #(
    parameter AXI_DATA_WIDTH = `VX_MEM_DATA_WIDTH, 
    parameter AXI_ADDR_WIDTH = `XLEN,
    parameter AXI_TID_WIDTH  = `VX_MEM_TAG_WIDTH
)(
    // Clock
    input  wire                         clk,
    input  wire                         reset,

    // AXI write request address channel    
    output wire                         m_axi_awvalid,
    input wire                          m_axi_awready,
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_awaddr,
    output wire [AXI_TID_WIDTH-1:0]     m_axi_awid,
    output wire [7:0]                   m_axi_awlen,
    output wire [2:0]                   m_axi_awsize,
    output wire [1:0]                   m_axi_awburst,  
    output wire [1:0]                   m_axi_awlock,    
    output wire [3:0]                   m_axi_awcache,
    output wire [2:0]                   m_axi_awprot,        
    output wire [3:0]                   m_axi_awqos,
    output wire [3:0]                   m_axi_awregion,

    // AXI write request data channel     
    output wire                         m_axi_wvalid, 
    input wire                          m_axi_wready,
    output wire [AXI_DATA_WIDTH-1:0]    m_axi_wdata,
    output wire [AXI_DATA_WIDTH/8-1:0]  m_axi_wstrb,    
    output wire                         m_axi_wlast,  

    // AXI write response channel
    input wire                          m_axi_bvalid,
    output wire                         m_axi_bready,
    input wire [AXI_TID_WIDTH-1:0]      m_axi_bid,
    input wire [1:0]                    m_axi_bresp,
    
    // AXI read request channel
    output wire                         m_axi_arvalid,
    input wire                          m_axi_arready,
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_araddr,
    output wire [AXI_TID_WIDTH-1:0]     m_axi_arid,
    output wire [7:0]                   m_axi_arlen,
    output wire [2:0]                   m_axi_arsize,
    output wire [1:0]                   m_axi_arburst,            
    output wire [1:0]                   m_axi_arlock,    
    output wire [3:0]                   m_axi_arcache,
    output wire [2:0]                   m_axi_arprot,        
    output wire [3:0]                   m_axi_arqos, 
    output wire [3:0]                   m_axi_arregion,
    
    // AXI read response channel
    input wire                          m_axi_rvalid,
    output wire                         m_axi_rready,
    input wire [AXI_DATA_WIDTH-1:0]     m_axi_rdata,
    input wire                          m_axi_rlast,
    input wire [AXI_TID_WIDTH-1:0]      m_axi_rid,
    input wire [1:0]                    m_axi_rresp,
    
    // DCR write request
    input  wire                         dcr_wr_valid,
    input  wire [`VX_DCR_ADDR_WIDTH-1:0] dcr_wr_addr,
    input  wire [`VX_DCR_DATA_WIDTH-1:0] dcr_wr_data,

    // Status
    output wire                         busy
);
    `STATIC_ASSERT((AXI_DATA_WIDTH == `VX_MEM_DATA_WIDTH), ("invalid memory data size: current=%0d, expected=%0d", AXI_DATA_WIDTH, `VX_MEM_DATA_WIDTH))
    `STATIC_ASSERT((AXI_ADDR_WIDTH >= `XLEN), ("invalid memory address size: current=%0d, expected=%0d", AXI_ADDR_WIDTH, `VX_MEM_ADDR_WIDTH))
    `STATIC_ASSERT((AXI_TID_WIDTH >= `VX_MEM_TAG_WIDTH), ("invalid memory tag size: current=%0d, expected=%0d", AXI_TID_WIDTH, `VX_MEM_TAG_WIDTH))
    
    wire                            mem_req_valid;
    wire                            mem_req_rw; 
    wire [`VX_MEM_BYTEEN_WIDTH-1:0] mem_req_byteen;
    wire [`VX_MEM_ADDR_WIDTH-1:0]   mem_req_addr;
    wire [`VX_MEM_DATA_WIDTH-1:0]   mem_req_data;
    wire [`VX_MEM_TAG_WIDTH-1:0]    mem_req_tag;
    wire                            mem_req_ready;

    wire                            mem_rsp_valid;        
    wire [`VX_MEM_DATA_WIDTH-1:0]   mem_rsp_data;
    wire [`VX_MEM_TAG_WIDTH-1:0]    mem_rsp_tag;
    wire                            mem_rsp_ready;

    wire [`XLEN-1:0] m_axi_awaddr_unqual;
    wire [`XLEN-1:0] m_axi_araddr_unqual;

    wire [`VX_MEM_TAG_WIDTH-1:0] m_axi_awid_unqual;
    wire [`VX_MEM_TAG_WIDTH-1:0] m_axi_arid_unqual;
    
    wire [`VX_MEM_TAG_WIDTH-1:0] m_axi_bid_unqual;    
    wire [`VX_MEM_TAG_WIDTH-1:0] m_axi_rid_unqual;

    assign m_axi_awaddr = `XLEN'(m_axi_awaddr_unqual);
	assign m_axi_araddr = `XLEN'(m_axi_araddr_unqual);
    
    assign m_axi_awid = AXI_TID_WIDTH'(m_axi_awid_unqual);
    assign m_axi_arid = AXI_TID_WIDTH'(m_axi_arid_unqual);

    assign m_axi_rid_unqual = `VX_MEM_TAG_WIDTH'(m_axi_rid);
    assign m_axi_bid_unqual = `VX_MEM_TAG_WIDTH'(m_axi_bid);

    VX_axi_adapter #(
        .DATA_WIDTH (`VX_MEM_DATA_WIDTH), 
        .ADDR_WIDTH (`XLEN),
        .TAG_WIDTH  (`VX_MEM_TAG_WIDTH)
    ) axi_adapter (
        .clk            (clk),
        .reset          (reset),

        .mem_req_valid  (mem_req_valid),
        .mem_req_rw     (mem_req_rw),
        .mem_req_byteen (mem_req_byteen),
        .mem_req_addr   (mem_req_addr),
        .mem_req_data   (mem_req_data),
        .mem_req_tag    (mem_req_tag),
        .mem_req_ready  (mem_req_ready),

        .mem_rsp_valid  (mem_rsp_valid),
        .mem_rsp_data   (mem_rsp_data),
        .mem_rsp_tag    (mem_rsp_tag),
        .mem_rsp_ready  (mem_rsp_ready),
                
        .m_axi_awvalid  (m_axi_awvalid),
        .m_axi_awready  (m_axi_awready),
        .m_axi_awaddr   (m_axi_awaddr_unqual),
        .m_axi_awid     (m_axi_awid_unqual),
        .m_axi_awlen    (m_axi_awlen),
        .m_axi_awsize   (m_axi_awsize),
        .m_axi_awburst  (m_axi_awburst),  
        .m_axi_awlock   (m_axi_awlock),    
        .m_axi_awcache  (m_axi_awcache),
        .m_axi_awprot   (m_axi_awprot),        
        .m_axi_awqos    (m_axi_awqos),  
        .m_axi_awregion (m_axi_awregion),

        .m_axi_wvalid   (m_axi_wvalid),
        .m_axi_wready   (m_axi_wready),
        .m_axi_wdata    (m_axi_wdata),
        .m_axi_wstrb    (m_axi_wstrb),
        .m_axi_wlast    (m_axi_wlast),
        
        .m_axi_bvalid   (m_axi_bvalid),
        .m_axi_bready   (m_axi_bready),
        .m_axi_bid      (m_axi_bid_unqual),
        .m_axi_bresp    (m_axi_bresp),
        
        .m_axi_arvalid  (m_axi_arvalid),
        .m_axi_arready  (m_axi_arready),
        .m_axi_araddr   (m_axi_araddr_unqual),
        .m_axi_arid     (m_axi_arid_unqual),        
        .m_axi_arlen    (m_axi_arlen),
        .m_axi_arsize   (m_axi_arsize),
        .m_axi_arburst  (m_axi_arburst), 
        .m_axi_arlock   (m_axi_arlock),    
        .m_axi_arcache  (m_axi_arcache),
        .m_axi_arprot   (m_axi_arprot),        
        .m_axi_arqos    (m_axi_arqos),
        .m_axi_arregion (m_axi_arregion),        
        
        .m_axi_rvalid   (m_axi_rvalid),
        .m_axi_rready   (m_axi_rready),
        .m_axi_rdata    (m_axi_rdata),        
        .m_axi_rlast    (m_axi_rlast) ,       
        .m_axi_rid      (m_axi_rid_unqual),
        .m_axi_rresp    (m_axi_rresp)
    );
    
    Vortex vortex (
        .clk            (clk),
        .reset          (reset),

        .mem_req_valid  (mem_req_valid),
        .mem_req_rw     (mem_req_rw),
        .mem_req_byteen (mem_req_byteen),
        .mem_req_addr   (mem_req_addr),
        .mem_req_data   (mem_req_data),
        .mem_req_tag    (mem_req_tag),
        .mem_req_ready  (mem_req_ready),

        .mem_rsp_valid  (mem_rsp_valid),
        .mem_rsp_data   (mem_rsp_data),
        .mem_rsp_tag    (mem_rsp_tag),
        .mem_rsp_ready  (mem_rsp_ready),

        .dcr_wr_valid   (dcr_wr_valid),
        .dcr_wr_addr    (dcr_wr_addr),
        .dcr_wr_data    (dcr_wr_data),

        .busy           (busy)
    );

endmodule