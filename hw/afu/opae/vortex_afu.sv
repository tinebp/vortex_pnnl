`include "VX_platform.vh"
`ifdef NOPAE
`IGNORE_WARNINGS_BEGIN
`include "vortex_afu.vh"
`IGNORE_WARNINGS_END
`else
`include "afu_json_info.vh"
`endif

`include "VX_define.vh"
`include "VX_gpu_types.vh"

/* verilator lint_off IMPORTSTAR */ 
import ccip_if_pkg::*;
import local_mem_cfg_pkg::*;
import VX_gpu_types::*;
/* verilator lint_on IMPORTSTAR */

module vortex_afu #(
  parameter NUM_LOCAL_MEM_BANKS = 2
) (
  // global signals
  input wire clk,
  input wire reset,

  // IF signals between CCI and AFU
  input   t_if_ccip_Rx  cp2af_sRxPort,
  output  t_if_ccip_Tx  af2cp_sTxPort,

  // Avalon signals for local memory access
  output  t_local_mem_data      avs_writedata [NUM_LOCAL_MEM_BANKS],
  input   t_local_mem_data      avs_readdata [NUM_LOCAL_MEM_BANKS],
  output  t_local_mem_addr      avs_address [NUM_LOCAL_MEM_BANKS],
  input   wire                  avs_waitrequest [NUM_LOCAL_MEM_BANKS],
  output  wire                  avs_write [NUM_LOCAL_MEM_BANKS],
  output  wire                  avs_read [NUM_LOCAL_MEM_BANKS],
  output  t_local_mem_byte_mask avs_byteenable [NUM_LOCAL_MEM_BANKS],
  output  t_local_mem_burst_cnt avs_burstcount [NUM_LOCAL_MEM_BANKS],
  input   wire                  avs_readdatavalid [NUM_LOCAL_MEM_BANKS]
);

localparam LMEM_DATA_WIDTH    = $bits(t_local_mem_data);
localparam LMEM_ADDR_WIDTH    = $bits(t_local_mem_addr);
localparam LMEM_BURST_CTRW    = $bits(t_local_mem_burst_cnt);

localparam CCI_DATA_WIDTH     = $bits(t_ccip_clData);
localparam CCI_DATA_SIZE      = CCI_DATA_WIDTH / 8;
localparam CCI_ADDR_WIDTH     = 32 - $clog2(CCI_DATA_SIZE);


localparam AVS_RD_QUEUE_SIZE  = 32;
localparam _VX_MEM_TAG_WIDTH  = `VX_MEM_TAG_WIDTH;
localparam _AVS_REQ_TAGW_VX   = _VX_MEM_TAG_WIDTH + $clog2(LMEM_DATA_WIDTH) - $clog2(`VX_MEM_DATA_WIDTH);
localparam _AVS_REQ_TAGW_VX2  = `MAX(_VX_MEM_TAG_WIDTH, _AVS_REQ_TAGW_VX);
localparam _AVS_REQ_TAGW_CCI  = CCI_ADDR_WIDTH + $clog2(LMEM_DATA_WIDTH) - $clog2(CCI_DATA_WIDTH);
localparam _AVS_REQ_TAGW_CCI2 = `MAX(CCI_ADDR_WIDTH, _AVS_REQ_TAGW_CCI);
localparam AVS_REQ_TAGW       = `MAX(_AVS_REQ_TAGW_VX2, _AVS_REQ_TAGW_CCI2);

localparam CCI_RD_WINDOW_SIZE = 8;
localparam CCI_RW_PENDING_SIZE= 256;

localparam AFU_ID_L           = 16'h0002;      // AFU ID Lower
localparam AFU_ID_H           = 16'h0004;      // AFU ID Higher 

localparam CMD_MEM_READ       = `AFU_IMAGE_CMD_MEM_READ;
localparam CMD_MEM_WRITE      = `AFU_IMAGE_CMD_MEM_WRITE;
localparam CMD_DCR_WRITE      = `AFU_IMAGE_CMD_DCR_WRITE;
localparam CMD_RUN            = `AFU_IMAGE_CMD_RUN;
localparam CMD_TYPE_WIDTH     = $clog2(`AFU_IMAGE_CMD_MAX_VALUE+1);

localparam MMIO_CMD_TYPE      = `AFU_IMAGE_MMIO_CMD_TYPE; 
localparam MMIO_CMD_ARG0      = `AFU_IMAGE_MMIO_CMD_ARG0;
localparam MMIO_CMD_ARG1      = `AFU_IMAGE_MMIO_CMD_ARG1;
localparam MMIO_CMD_ARG2      = `AFU_IMAGE_MMIO_CMD_ARG2;
localparam MMIO_STATUS        = `AFU_IMAGE_MMIO_STATUS;

localparam COUT_TID_WIDTH     = $clog2(`VX_MEM_BYTEEN_WIDTH); 
localparam COUT_QUEUE_DATAW   = COUT_TID_WIDTH + 8;
localparam COUT_QUEUE_SIZE    = 64; 

localparam MMIO_SCOPE_READ    = `AFU_IMAGE_MMIO_SCOPE_READ;
localparam MMIO_SCOPE_WRITE   = `AFU_IMAGE_MMIO_SCOPE_WRITE;

localparam MMIO_DEV_CAPS      = `AFU_IMAGE_MMIO_DEV_CAPS;
localparam MMIO_ISA_CAPS      = `AFU_IMAGE_MMIO_ISA_CAPS;

localparam CCI_RD_QUEUE_SIZE  = 2 * CCI_RD_WINDOW_SIZE;
localparam CCI_RD_QUEUE_TAGW  = $clog2(CCI_RD_WINDOW_SIZE);
localparam CCI_RD_QUEUE_DATAW = CCI_DATA_WIDTH + CCI_ADDR_WIDTH;

localparam STATE_IDLE         = 0;
localparam STATE_MEM_WRITE    = 1;
localparam STATE_MEM_READ     = 2;
localparam STATE_RUN          = 3;
localparam STATE_DCR_WRITE    = 4;
localparam STATE_WIDTH        = $clog2(STATE_DCR_WRITE+1);

`ifdef SCOPE
`SCOPE_DECL_SIGNALS
`endif

wire [127:0] afu_id = `AFU_ACCEL_UUID;

wire [63:0] dev_caps = {16'(`NUM_THREADS), 16'(`NUM_WARPS), 16'(`NUM_CORES * `NUM_CLUSTERS), 16'(`IMPLEMENTATION_ID)};

wire [63:0] isa_caps = {32'(`MISA_EXT), 2'($clog2(`XLEN)-4), 30'(`MISA_STD)};

reg [STATE_WIDTH-1:0] state;

// Vortex ports ///////////////////////////////////////////////////////////////

wire vx_mem_req_valid;
wire vx_mem_req_rw;
wire [`VX_MEM_BYTEEN_WIDTH-1:0] vx_mem_req_byteen;
wire [`VX_MEM_ADDR_WIDTH-1:0]   vx_mem_req_addr;
wire [`VX_MEM_DATA_WIDTH-1:0]   vx_mem_req_data;
wire [`VX_MEM_TAG_WIDTH-1:0]    vx_mem_req_tag;
wire vx_mem_req_ready;

wire vx_mem_rsp_valid;
wire [`VX_MEM_DATA_WIDTH-1:0]   vx_mem_rsp_data;
wire [`VX_MEM_TAG_WIDTH-1:0]    vx_mem_rsp_tag;
wire vx_mem_rsp_ready;

reg  vx_reset;
wire vx_busy;

// CMD variables //////////////////////////////////////////////////////////////

reg [2:0][63:0] cmd_args;

t_ccip_clAddr cmd_io_addr;
assign cmd_io_addr = t_ccip_clAddr'(cmd_args[0]);

wire [CCI_ADDR_WIDTH-1:0] cmd_mem_addr  = CCI_ADDR_WIDTH'(cmd_args[1]);
wire [CCI_ADDR_WIDTH-1:0] cmd_data_size = CCI_ADDR_WIDTH'(cmd_args[2]);

wire [`VX_DCR_ADDR_WIDTH-1:0] cmd_dcr_addr = `VX_DCR_ADDR_WIDTH'(cmd_args[0]);
wire [`VX_DCR_DATA_WIDTH-1:0] cmd_dcr_data = `VX_DCR_DATA_WIDTH'(cmd_args[1]);

`ifdef SCOPE
wire [63:0]   cmd_scope_rdata;
wire [63:0]   cmd_scope_wdata;  
wire          cmd_scope_read;
wire          cmd_scope_write;
`endif

// MMIO controller ////////////////////////////////////////////////////////////

`IGNORE_UNUSED_BEGIN
t_ccip_c0_ReqMmioHdr mmio_hdr;
`IGNORE_UNUSED_END
assign mmio_hdr = t_ccip_c0_ReqMmioHdr'(cp2af_sRxPort.c0.hdr);

`STATIC_ASSERT(($bits(t_ccip_c0_ReqMmioHdr)-$bits(mmio_hdr.address)) == 12, ("Oops!"))

t_if_ccip_c2_Tx mmio_tx;
assign af2cp_sTxPort.c2 = mmio_tx;

`ifdef SCOPE
assign cmd_scope_wdata = 64'(cp2af_sRxPort.c0.data);
assign cmd_scope_read  = cp2af_sRxPort.c0.mmioRdValid && (MMIO_SCOPE_READ == mmio_hdr.address);
assign cmd_scope_write = cp2af_sRxPort.c0.mmioWrValid && (MMIO_SCOPE_WRITE == mmio_hdr.address);
`endif

wire [COUT_QUEUE_DATAW-1:0] cout_q_dout;
wire cout_q_full, cout_q_empty;

`ifdef SIMULATION
`ifndef VERILATOR
// disable assertions until full reset
reg [$clog2(`RESET_DELAY+1)-1:0] assert_delay_ctr;
initial begin
  $assertoff;  
end
always @(posedge clk) begin
  if (reset) begin
    assert_delay_ctr <= 0;
  end else begin
    assert_delay_ctr <= assert_delay_ctr + $bits(assert_delay_ctr)'(1);
    if (assert_delay_ctr == (`RESET_DELAY-1)) begin
      $asserton; // enable assertions
    end
  end
end
`endif
`endif

always @(posedge clk) begin
  if (reset) begin
    mmio_tx.mmioRdValid <= 0;
    mmio_tx.hdr         <= 0;
  end else begin
    mmio_tx.mmioRdValid <= cp2af_sRxPort.c0.mmioRdValid; 
    mmio_tx.hdr.tid     <= mmio_hdr.tid;    
  end

  // serve MMIO write request
  if (cp2af_sRxPort.c0.mmioWrValid) begin
    case (mmio_hdr.address)
      MMIO_CMD_ARG0: begin
        cmd_args[0] <= 64'(cp2af_sRxPort.c0.data);
      `ifdef DBG_TRACE_AFU 
        `TRACE(2, ("%d: MMIO_CMD_ARG0: data=0x%0h\n", $time, 64'(cp2af_sRxPort.c0.data)));
      `endif
      end
      MMIO_CMD_ARG1: begin
        cmd_args[1] <= 64'(cp2af_sRxPort.c0.data);
      `ifdef DBG_TRACE_AFU
        `TRACE(2, ("%d: MMIO_CMD_ARG1: data=0x%0h\n", $time, 64'(cp2af_sRxPort.c0.data)));
      `endif
      end
      MMIO_CMD_ARG2: begin
        cmd_args[2] <= 64'(cp2af_sRxPort.c0.data);
      `ifdef DBG_TRACE_AFU
        `TRACE(2, ("%d: MMIO_CMD_ARG2: data=%0d\n", $time, 64'(cp2af_sRxPort.c0.data)));
      `endif
      end
      MMIO_CMD_TYPE: begin
      `ifdef DBG_TRACE_AFU
        `TRACE(2, ("%d: MMIO_CMD_TYPE: data=%0d\n", $time, 64'(cp2af_sRxPort.c0.data)));
      `endif
      end
    `ifdef SCOPE
      MMIO_SCOPE_WRITE: begin
      `ifdef DBG_TRACE_AFU
        `TRACE(2, ("%d: MMIO_SCOPE_WRITE: data=0x%0h\n", $time, 64'(cp2af_sRxPort.c0.data)));
      `endif
      end
    `endif
      default: begin
        `ifdef DBG_TRACE_AFU
          `TRACE(2, ("%d: Unknown MMIO Wr: addr=0x%0h, data=0x%0h\n", $time, mmio_hdr.address, 64'(cp2af_sRxPort.c0.data)));
        `endif
      end
    endcase
  end

  // serve MMIO read requests
  if (cp2af_sRxPort.c0.mmioRdValid) begin
    case (mmio_hdr.address)
      // AFU header
      16'h0000: mmio_tx.data <= {
        4'b0001, // Feature type = AFU
        8'b0,    // reserved
        4'b0,    // afu minor revision = 0
        7'b0,    // reserved
        1'b1,    // end of DFH list = 1 
        24'b0,   // next DFH offset = 0
        4'b0,    // afu major revision = 0
        12'b0    // feature ID = 0
      };
      AFU_ID_L: mmio_tx.data <= afu_id[63:0];   // afu id low
      AFU_ID_H: mmio_tx.data <= afu_id[127:64]; // afu id hi
      16'h0006: mmio_tx.data <= 64'h0; // next AFU
      16'h0008: mmio_tx.data <= 64'h0; // reserved
      MMIO_STATUS: begin
        mmio_tx.data <= 64'({cout_q_dout, !cout_q_empty, 8'(state)});
      `ifdef DBG_TRACE_AFU
        if (state != STATE_WIDTH'(mmio_tx.data)) begin
          `TRACE(2, ("%d: MMIO_STATUS: addr=0x%0h, state=%0d\n", $time, mmio_hdr.address, state));
        end
      `endif
      end
    `ifdef SCOPE
      MMIO_SCOPE_READ: begin
        mmio_tx.data <= cmd_scope_rdata;
      `ifdef DBG_TRACE_AFU
        `TRACE(2, ("%d: MMIO_SCOPE_READ: data=0x%0h\n", $time, cmd_scope_rdata));
      `endif
      end
    `endif
      MMIO_DEV_CAPS: begin
        mmio_tx.data <= dev_caps;
      `ifdef DBG_TRACE_AFU
        `TRACE(2, ("%d: MMIO_DEV_CAPS: data=0x%0h\n", $time, dev_caps));
      `endif
      end      
      MMIO_ISA_CAPS: begin
        mmio_tx.data <= isa_caps;
      `ifdef DBG_TRACE_AFU
        if (state != STATE_WIDTH'(mmio_tx.data)) begin
          `TRACE(2, ("%d: MMIO_ISA_CAPS: data=%0d\n", $time, isa_caps));
        end
      `endif
      end
      default: begin
        mmio_tx.data <= 64'h0;
      `ifdef DBG_TRACE_AFU
        `TRACE(2, ("%d: Unknown MMIO Rd: addr=0x%0h\n", $time, mmio_hdr.address));
      `endif
      end
    endcase
  end
end

// COMMAND FSM ////////////////////////////////////////////////////////////////

wire cmd_mem_rd_done;
reg  cmd_mem_wr_done;
wire cmd_run_done;
reg  vx_running;

reg [$clog2(`RESET_DELAY+1)-1:0] vx_reset_ctr;
always @(posedge clk) begin
  if (state == STATE_IDLE) begin
    vx_reset_ctr <= 0;
  end else if (state == STATE_RUN) begin
    vx_reset_ctr <= vx_reset_ctr + $bits(vx_reset_ctr)'(1);
  end
end

wire is_mmio_wr_cmd = cp2af_sRxPort.c0.mmioWrValid && (MMIO_CMD_TYPE == mmio_hdr.address);
wire [CMD_TYPE_WIDTH-1:0] cmd_type = is_mmio_wr_cmd ? CMD_TYPE_WIDTH'(cp2af_sRxPort.c0.data) : CMD_TYPE_WIDTH'(0);

always @(posedge clk) begin
  if (reset) begin
    state      <= STATE_IDLE;
    vx_running <= 0;
    vx_reset   <= 0;    
  end else begin
    case (state)
      STATE_IDLE: begin             
        case (cmd_type)
          CMD_MEM_READ: begin     
          `ifdef DBG_TRACE_AFU
            `TRACE(2, ("%d: STATE MEM_READ: ia=0x%0h addr=0x%0h size=%0d\n", $time, cmd_io_addr, cmd_mem_addr, cmd_data_size));
          `endif
            state <= STATE_MEM_READ;   
          end 
          CMD_MEM_WRITE: begin      
          `ifdef DBG_TRACE_AFU
            `TRACE(2, ("%d: STATE MEM_WRITE: ia=0x%0h addr=0x%0h size=%0d\n", $time, cmd_io_addr, cmd_mem_addr, cmd_data_size));
          `endif
            state <= STATE_MEM_WRITE;
          end
          CMD_DCR_WRITE: begin      
          `ifdef DBG_TRACE_AFU
            `TRACE(2, ("%d: STATE DCR_WRITE: addr=0x%0h data=%0d\n", $time, cmd_dcr_addr, cmd_dcr_data));
          `endif
            state <= STATE_DCR_WRITE;
          end
          CMD_RUN: begin        
          `ifdef DBG_TRACE_AFU
            `TRACE(2, ("%d: STATE RUN\n", $time));
          `endif
            vx_reset <= 1;            
            state <= STATE_RUN;                    
          end
          default: begin
            state <= state;
          end
        endcase
      end      

      STATE_MEM_READ: begin
        if (cmd_mem_rd_done) begin
          state <= STATE_IDLE;
        `ifdef DBG_TRACE_AFU
          `TRACE(2, ("%d: STATE IDLE\n", $time));
        `endif
        end
      end

      STATE_MEM_WRITE: begin
        if (cmd_mem_wr_done) begin
          state <= STATE_IDLE;
        `ifdef DBG_TRACE_AFU
          `TRACE(2, ("%d: STATE IDLE\n", $time));
        `endif
        end
      end

      STATE_DCR_WRITE: begin
        state <= STATE_IDLE;
      `ifdef DBG_TRACE_AFU
        `TRACE(2, ("%d: STATE IDLE\n", $time));
      `endif
      end

      STATE_RUN: begin 
        // vortex reset cycles
        if (vx_running) begin
          if (cmd_run_done) begin
            vx_running <= 0;
            state <= STATE_IDLE;
          `ifdef DBG_TRACE_AFU
            `TRACE(2, ("%d: STATE IDLE\n", $time));
          `endif
          end
        end else begin
          if (vx_reset_ctr == (`RESET_DELAY-1)) begin
            vx_running <= 1;
            vx_reset   <= 0;
          end  
        end        
      end

      default:;

    endcase
  end
end

// AVS Controller /////////////////////////////////////////////////////////////

wire cci_mem_rd_req_valid;
wire cci_mem_wr_req_valid;
wire [CCI_RD_QUEUE_DATAW-1:0] cci_rdq_dout;

wire cci_mem_req_valid;
wire cci_mem_req_rw;
wire [CCI_ADDR_WIDTH-1:0] cci_mem_req_addr;
wire [CCI_DATA_WIDTH-1:0] cci_mem_req_data;
wire [CCI_ADDR_WIDTH-1:0] cci_mem_req_tag;
wire cci_mem_req_ready;

wire cci_mem_rsp_valid;        
wire [CCI_DATA_WIDTH-1:0] cci_mem_rsp_data;
wire [CCI_ADDR_WIDTH-1:0] cci_mem_rsp_tag;
wire cci_mem_rsp_ready;

//--

VX_mem_req_if #(
  .DATA_WIDTH ($bits(t_local_mem_data)),
  .ADDR_WIDTH ($bits(t_local_mem_addr)),
  .TAG_WIDTH  (AVS_REQ_TAGW)
) cci_vx_mem_req_if[1:0]();

VX_mem_rsp_if #(
  .DATA_WIDTH ($bits(t_local_mem_data)),
  .TAG_WIDTH  (AVS_REQ_TAGW)
) cci_vx_mem_rsp_if[1:0]();

VX_mem_adapter #(
  .SRC_DATA_WIDTH (CCI_DATA_WIDTH), 
  .DST_DATA_WIDTH (LMEM_DATA_WIDTH), 
  .SRC_ADDR_WIDTH (CCI_ADDR_WIDTH),  
  .DST_ADDR_WIDTH (LMEM_ADDR_WIDTH),         
  .SRC_TAG_WIDTH  (CCI_ADDR_WIDTH),
  .DST_TAG_WIDTH  (AVS_REQ_TAGW)
) cci_mem_adapter (
  .clk                (clk),
  .reset              (reset),

  .mem_req_valid_in   (cci_mem_req_valid),
  .mem_req_addr_in    (cci_mem_req_addr),
  .mem_req_rw_in      (cci_mem_req_rw),
  .mem_req_byteen_in  ({CCI_DATA_SIZE{1'b1}}),
  .mem_req_data_in    (cci_mem_req_data),
  .mem_req_tag_in     (cci_mem_req_tag), 
  .mem_req_ready_in   (cci_mem_req_ready), 

  .mem_req_valid_out  (cci_vx_mem_req_if[1].valid),
  .mem_req_addr_out   (cci_vx_mem_req_if[1].addr),
  .mem_req_rw_out     (cci_vx_mem_req_if[1].rw),
  .mem_req_byteen_out (cci_vx_mem_req_if[1].byteen),
  .mem_req_data_out   (cci_vx_mem_req_if[1].data),
  .mem_req_tag_out    (cci_vx_mem_req_if[1].tag),
  .mem_req_ready_out  (cci_vx_mem_req_if[1].ready), 

  .mem_rsp_valid_in   (cci_vx_mem_rsp_if[1].valid), 
  .mem_rsp_data_in    (cci_vx_mem_rsp_if[1].data), 
  .mem_rsp_tag_in     (cci_vx_mem_rsp_if[1].tag), 
  .mem_rsp_ready_in   (cci_vx_mem_rsp_if[1].ready),

  .mem_rsp_valid_out  (cci_mem_rsp_valid), 
  .mem_rsp_data_out   (cci_mem_rsp_data), 
  .mem_rsp_tag_out    (cci_mem_rsp_tag), 
  .mem_rsp_ready_out  (cci_mem_rsp_ready) 
);

//--

wire vx_mem_is_cout;
wire vx_mem_req_valid_qual;
wire vx_mem_req_ready_qual;

assign vx_mem_req_valid_qual = vx_mem_req_valid && ~vx_mem_is_cout && vx_running;

VX_mem_adapter #(
  .SRC_DATA_WIDTH (`VX_MEM_DATA_WIDTH),
  .DST_DATA_WIDTH (LMEM_DATA_WIDTH),  
  .SRC_ADDR_WIDTH (`VX_MEM_ADDR_WIDTH),    
  .DST_ADDR_WIDTH (LMEM_ADDR_WIDTH),
  .SRC_TAG_WIDTH  (`VX_MEM_TAG_WIDTH),
  .DST_TAG_WIDTH  (AVS_REQ_TAGW)
) vx_mem_adapter (
  .clk                (clk),
  .reset              (reset),

  .mem_req_valid_in   (vx_mem_req_valid_qual),
  .mem_req_addr_in    (vx_mem_req_addr),
  .mem_req_rw_in      (vx_mem_req_rw),
  .mem_req_byteen_in  (vx_mem_req_byteen),
  .mem_req_data_in    (vx_mem_req_data),
  .mem_req_tag_in     (vx_mem_req_tag), 
  .mem_req_ready_in   (vx_mem_req_ready_qual), 

  .mem_req_valid_out  (cci_vx_mem_req_if[0].valid),
  .mem_req_addr_out   (cci_vx_mem_req_if[0].addr),
  .mem_req_rw_out     (cci_vx_mem_req_if[0].rw),
  .mem_req_byteen_out (cci_vx_mem_req_if[0].byteen),
  .mem_req_data_out   (cci_vx_mem_req_if[0].data),
  .mem_req_tag_out    (cci_vx_mem_req_if[0].tag),
  .mem_req_ready_out  (cci_vx_mem_req_if[0].ready), 

  .mem_rsp_valid_in   (cci_vx_mem_rsp_if[0].valid), 
  .mem_rsp_data_in    (cci_vx_mem_rsp_if[0].data), 
  .mem_rsp_tag_in     (cci_vx_mem_rsp_if[0].tag), 
  .mem_rsp_ready_in   (cci_vx_mem_rsp_if[0].ready),

  .mem_rsp_valid_out  (vx_mem_rsp_valid), 
  .mem_rsp_data_out   (vx_mem_rsp_data), 
  .mem_rsp_tag_out    (vx_mem_rsp_tag), 
  .mem_rsp_ready_out  (vx_mem_rsp_ready) 
);

//--
VX_mem_req_if #(
  .DATA_WIDTH ($bits(t_local_mem_data)),
  .ADDR_WIDTH ($bits(t_local_mem_addr)),
  .TAG_WIDTH  (AVS_REQ_TAGW+1)
) mem_req_if();

VX_mem_rsp_if #(
  .DATA_WIDTH ($bits(t_local_mem_data)),
  .TAG_WIDTH  (AVS_REQ_TAGW+1)
) mem_rsp_if();

`RESET_RELAY (mem_arb_reset, reset);

VX_mem_arb #(
  .NUM_REQS     (2),
  .DATA_WIDTH   (LMEM_DATA_WIDTH),
  .ADDR_WIDTH   (LMEM_ADDR_WIDTH),
  .TAG_WIDTH    (AVS_REQ_TAGW),
  .ARBITER      ("P"),
  .BUFFERED_REQ (1),
  .BUFFERED_RSP (2)
) mem_arb (
  .clk        (clk),
  .reset      (mem_arb_reset),
  .req_in_if  (cci_vx_mem_req_if),
  .rsp_in_if  (cci_vx_mem_rsp_if),
  .req_out_if (mem_req_if),
  .rsp_out_if (mem_rsp_if)
);

//--

`RESET_RELAY (avs_adapter_reset, reset);

VX_avs_adapter #(
  .AVS_DATA_WIDTH  (LMEM_DATA_WIDTH), 
  .AVS_ADDR_WIDTH  (LMEM_ADDR_WIDTH),
  .AVS_BURST_WIDTH (LMEM_BURST_CTRW),
  .AVS_BANKS       (NUM_LOCAL_MEM_BANKS),
  .REQ_TAG_WIDTH   (AVS_REQ_TAGW + 1),
  .RD_QUEUE_SIZE   (AVS_RD_QUEUE_SIZE)
) avs_adapter (
  .clk              (clk),
  .reset            (avs_adapter_reset),

  // Memory request 
  .mem_req_valid    (mem_req_if.valid),
  .mem_req_rw       (mem_req_if.rw),
  .mem_req_byteen   (mem_req_if.byteen),
  .mem_req_addr     (mem_req_if.addr),
  .mem_req_data     (mem_req_if.data),
  .mem_req_tag      (mem_req_if.tag),
  .mem_req_ready    (mem_req_if.ready),

  // Memory response  
  .mem_rsp_valid    (mem_rsp_if.valid),
  .mem_rsp_data     (mem_rsp_if.data),
  .mem_rsp_tag      (mem_rsp_if.tag),
  .mem_rsp_ready    (mem_rsp_if.ready),

  // AVS bus
  .avs_writedata    (avs_writedata),
  .avs_readdata     (avs_readdata),
  .avs_address      (avs_address),
  .avs_waitrequest  (avs_waitrequest),
  .avs_write        (avs_write),
  .avs_read         (avs_read),
  .avs_byteenable   (avs_byteenable),
  .avs_burstcount   (avs_burstcount),
  .avs_readdatavalid(avs_readdatavalid)
);

// CCI-P Read Request ///////////////////////////////////////////////////////////

reg [CCI_ADDR_WIDTH-1:0] cci_mem_wr_req_ctr;
wire [CCI_ADDR_WIDTH-1:0] cci_mem_wr_req_addr;
reg [CCI_ADDR_WIDTH-1:0] cci_mem_wr_req_addr_base;

wire cci_rd_req_fire;
t_ccip_clAddr cci_rd_req_addr;
reg cci_rd_req_valid, cci_rd_req_wait;
reg [CCI_ADDR_WIDTH-1:0] cci_rd_req_ctr;
wire [CCI_ADDR_WIDTH-1:0] cci_rd_req_ctr_next;
wire [CCI_RD_QUEUE_TAGW-1:0] cci_rd_req_tag;

wire [CCI_RD_QUEUE_TAGW-1:0] cci_rd_rsp_tag;
reg [CCI_RD_QUEUE_TAGW-1:0] cci_rd_rsp_ctr;

wire cci_rdq_push, cci_rdq_pop;
wire [CCI_RD_QUEUE_DATAW-1:0] cci_rdq_din;
wire cci_rdq_empty;

always @(*) begin
  af2cp_sTxPort.c0.valid       = cci_rd_req_fire;
  af2cp_sTxPort.c0.hdr         = t_ccip_c0_ReqMemHdr'(0);
  af2cp_sTxPort.c0.hdr.address = cci_rd_req_addr;  
  af2cp_sTxPort.c0.hdr.mdata   = t_ccip_mdata'(cci_rd_req_tag);
end

wire cci_mem_wr_req_fire = cci_mem_wr_req_valid && cci_mem_req_ready;

wire cci_rd_rsp_fire = cp2af_sRxPort.c0.rspValid 
                    && (cp2af_sRxPort.c0.hdr.resp_type == eRSP_RDLINE);

assign cci_rd_req_tag = CCI_RD_QUEUE_TAGW'(cci_rd_req_ctr);
assign cci_rd_rsp_tag = CCI_RD_QUEUE_TAGW'(cp2af_sRxPort.c0.hdr.mdata);

assign cci_rdq_push = cci_rd_rsp_fire;
assign cci_rdq_pop  = cci_mem_wr_req_fire;
assign cci_rdq_din  = {cp2af_sRxPort.c0.data, cci_mem_wr_req_addr_base + CCI_ADDR_WIDTH'(cci_rd_rsp_tag)};

wire [$clog2(CCI_RD_QUEUE_SIZE+1)-1:0] cci_pending_reads;
wire cci_pending_reads_full;
VX_pending_size #( 
    .SIZE (CCI_RD_QUEUE_SIZE)
) cci_rd_pending_size (
    .clk   (clk),
    .reset (reset),
    .incr  (cci_rd_req_fire),
    .decr  (cci_rdq_pop),
    .full  (cci_pending_reads_full),
    .size  (cci_pending_reads),
    `UNUSED_PIN (empty)
);
`UNUSED_VAR (cci_pending_reads)

assign cci_rd_req_ctr_next = cci_rd_req_ctr + CCI_ADDR_WIDTH'(cci_rd_req_fire ? 1 : 0);

assign cci_rd_req_fire = cci_rd_req_valid && !(cci_rd_req_wait || cci_pending_reads_full);

assign cci_mem_wr_req_valid = !cci_rdq_empty;

assign cci_mem_wr_req_addr = cci_rdq_dout[CCI_ADDR_WIDTH-1:0];

// Send read requests to CCI
always @(posedge clk) begin
  if (reset) begin
    cci_rd_req_valid <= 0;
    cci_rd_req_wait  <= 0;
  end else begin              
    if ((STATE_IDLE == state) 
    &&  (CMD_MEM_WRITE == cmd_type)) begin
      cci_rd_req_valid <= (cmd_data_size != 0);
      cci_rd_req_wait  <= 0;
    end

    cci_rd_req_valid <= (STATE_MEM_WRITE == state)                       
                     && (cci_rd_req_ctr_next != cmd_data_size)
                     && !cp2af_sRxPort.c0TxAlmFull;    

    if (cci_rd_req_fire && (cci_rd_req_tag == CCI_RD_QUEUE_TAGW'(CCI_RD_WINDOW_SIZE-1))) begin
      cci_rd_req_wait <= 1; // end current request batch
    end

    if (cci_rd_rsp_fire && (cci_rd_rsp_ctr == CCI_RD_QUEUE_TAGW'(CCI_RD_WINDOW_SIZE-1))) begin
      cci_rd_req_wait <= 0; // begin new request batch
    end    
  end

  if ((STATE_IDLE == state) 
  &&  (CMD_MEM_WRITE == cmd_type)) begin
    cci_rd_req_addr    <= cmd_io_addr;
    cci_rd_req_ctr     <= 0;
    cci_rd_rsp_ctr     <= 0;
    cci_mem_wr_req_ctr <= 0;
    cci_mem_wr_req_addr_base <= cmd_mem_addr;
    cmd_mem_wr_done     <= 0;
  end

  if (cci_rd_req_fire) begin  
    cci_rd_req_addr <= cci_rd_req_addr + 1;
    cci_rd_req_ctr  <= cci_rd_req_ctr + $bits(cci_rd_req_ctr)'(1);
  `ifdef DBG_TRACE_AFU
    `TRACE(2, ("%d: CCI Rd Req: addr=0x%0h, tag=0x%0h, rem=%0d, pending=%0d\n", $time, cci_rd_req_addr, cci_rd_req_tag, (cmd_data_size - cci_rd_req_ctr - 1), cci_pending_reads));
  `endif
  end

  if (cci_rd_rsp_fire) begin
    cci_rd_rsp_ctr <= cci_rd_rsp_ctr + CCI_RD_QUEUE_TAGW'(1);
    if (CCI_RD_QUEUE_TAGW'(cci_rd_rsp_ctr) == CCI_RD_QUEUE_TAGW'(CCI_RD_WINDOW_SIZE-1)) begin
      cci_mem_wr_req_addr_base <= cci_mem_wr_req_addr_base + CCI_ADDR_WIDTH'(CCI_RD_WINDOW_SIZE);
    end
  `ifdef DBG_TRACE_AFU
    `TRACE(2, ("%d: CCI Rd Rsp: idx=%0d, ctr=%0d, data=0x%0h\n", $time, cci_rd_rsp_tag, cci_rd_rsp_ctr, cp2af_sRxPort.c0.data));
  `endif
  end 

  if (cci_rdq_pop) begin
  `ifdef DBG_TRACE_AFU
    `TRACE(2, ("%d: CCI Rd Queue Pop: pending=%0d\n", $time, cci_pending_reads));
  `endif
  end

  if (cci_mem_wr_req_fire) begin    
    cci_mem_wr_req_ctr <= cci_mem_wr_req_ctr + CCI_ADDR_WIDTH'(1);
    if (cci_mem_wr_req_ctr == (cmd_data_size-1)) begin
      cmd_mem_wr_done <= 1;
    end
  end
end

`RESET_RELAY (cci_rdq_reset, reset);

VX_fifo_queue #(
  .DATAW   (CCI_RD_QUEUE_DATAW),
  .SIZE    (CCI_RD_QUEUE_SIZE),
  .OUT_REG (1)
) cci_rd_req_queue (
  .clk      (clk),
  .reset    (cci_rdq_reset),
  .push     (cci_rdq_push),
  .pop      (cci_rdq_pop),
  .data_in  (cci_rdq_din),
  .data_out (cci_rdq_dout),
  .empty    (cci_rdq_empty),
  `UNUSED_PIN (full),
  `UNUSED_PIN (alm_empty),
  `UNUSED_PIN (alm_full),
  `UNUSED_PIN (size)
);

`ifdef VERILATOR
`DEBUG_BLOCK(
  reg [CCI_RD_WINDOW_SIZE-1:0] dbg_cci_rd_rsp_mask;
  always @(posedge clk) begin
    if (reset) begin
      dbg_cci_rd_rsp_mask <= 0;
    end else begin
      if (cci_rd_rsp_fire) begin      
        if (cci_rd_rsp_ctr == 0) begin
          dbg_cci_rd_rsp_mask <= (CCI_RD_WINDOW_SIZE'(1) << cci_rd_rsp_tag);               
        end else begin                
          assert(!dbg_cci_rd_rsp_mask[cci_rd_rsp_tag]);
          dbg_cci_rd_rsp_mask[cci_rd_rsp_tag] <= 1;
        end 
      end
    end
  end
)
`endif

// CCI-P Write Request //////////////////////////////////////////////////////////

reg [CCI_ADDR_WIDTH-1:0] cci_mem_rd_req_ctr;
reg [CCI_ADDR_WIDTH-1:0] cci_mem_rd_req_addr;
reg cci_mem_rd_req_done;

reg [CCI_ADDR_WIDTH-1:0] cci_wr_req_ctr;
reg           cci_wr_req_fire;
t_ccip_clAddr cci_wr_req_addr;
t_ccip_clData cci_wr_req_data;
reg cci_wr_req_done;

always @(*) begin
  af2cp_sTxPort.c1.valid       = cci_wr_req_fire;
  af2cp_sTxPort.c1.hdr         = t_ccip_c1_ReqMemHdr'(0);
  af2cp_sTxPort.c1.hdr.sop     = 1; // single line write mode
  af2cp_sTxPort.c1.hdr.address = cci_wr_req_addr;
  af2cp_sTxPort.c1.data        = cci_wr_req_data;  
end 

wire cci_mem_rd_req_fire = cci_mem_rd_req_valid && cci_mem_req_ready;
wire cci_mem_rd_rsp_fire = cci_mem_rsp_valid && cci_mem_rsp_ready;

wire cci_wr_rsp_fire = (STATE_MEM_READ == state) 
                    && cp2af_sRxPort.c1.rspValid 
                    && (cp2af_sRxPort.c1.hdr.resp_type == eRSP_WRLINE);

wire [$clog2(CCI_RW_PENDING_SIZE+1)-1:0] cci_pending_writes;
wire cci_pending_writes_empty;
wire cci_pending_writes_full;

VX_pending_size #( 
    .SIZE (CCI_RW_PENDING_SIZE)
) cci_wr_pending_size (
    .clk   (clk),
    .reset (reset),
    .incr  (cci_mem_rd_rsp_fire),
    .decr  (cci_wr_rsp_fire),
    .empty (cci_pending_writes_empty),
    .full  (cci_pending_writes_full),
    .size  (cci_pending_writes)
);
`UNUSED_VAR (cci_pending_writes)

assign cci_mem_rd_req_valid = (STATE_MEM_READ == state) 
                           && !cci_mem_rd_req_done;

assign cci_mem_rsp_ready = !cp2af_sRxPort.c1TxAlmFull 
                        && !cci_pending_writes_full;

assign cmd_mem_rd_done = cci_wr_req_done
                      && cci_pending_writes_empty;

// Send write requests to CCI
always @(posedge clk) 
begin
  if (reset) begin
    cci_wr_req_fire <= 0;
  end else begin
    cci_wr_req_fire <= cci_mem_rd_rsp_fire;
  end
    
  if ((STATE_IDLE == state) 
  &&  (CMD_MEM_READ == cmd_type)) begin
    cci_mem_rd_req_ctr  <= 0;
    cci_mem_rd_req_addr <= cmd_mem_addr;
    cci_mem_rd_req_done <= 0;
    cci_wr_req_ctr      <= cmd_data_size;
    cci_wr_req_done     <= 0;
  end  

  if (cci_mem_rd_req_fire) begin
    cci_mem_rd_req_addr <= cci_mem_rd_req_addr + CCI_ADDR_WIDTH'(1);       
    cci_mem_rd_req_ctr  <= cci_mem_rd_req_ctr + CCI_ADDR_WIDTH'(1);
    if (cci_mem_rd_req_ctr == (cmd_data_size-1)) begin
        cci_mem_rd_req_done <= 1;
    end  
  end

  cci_wr_req_addr <= cmd_io_addr + t_ccip_clAddr'(cci_mem_rsp_tag);
  cci_wr_req_data <= t_ccip_clData'(cci_mem_rsp_data);  

  if (cci_wr_req_fire) begin
    `ASSERT(cci_wr_req_ctr != 0, ("runtime error"));               
    cci_wr_req_ctr <= cci_wr_req_ctr - CCI_ADDR_WIDTH'(1);
    if (cci_wr_req_ctr == CCI_ADDR_WIDTH'(1)) begin
      cci_wr_req_done <= 1;
    end
  `ifdef DBG_TRACE_AFU
    `TRACE(2, ("%d: CCI Wr Req: addr=0x%0h, rem=%0d, pending=%0d, data=0x%0h\n", $time, cci_wr_req_addr, (cci_wr_req_ctr - 1), cci_pending_writes, af2cp_sTxPort.c1.data));
  `endif
  end

  if (cci_wr_rsp_fire) begin 
  `ifdef DBG_TRACE_AFU     
    `TRACE(2, ("%d: CCI Wr Rsp: pending=%0d\n", $time, cci_pending_writes));  
  `endif    
  end
end

//--

assign cci_mem_req_rw = state[0];
`STATIC_ASSERT(STATE_MEM_WRITE == 1, ("invalid value")); // 01
`STATIC_ASSERT(STATE_MEM_READ  == 2, ("invalid value")); // 10

assign cci_mem_req_valid = cci_mem_req_rw ? cci_mem_wr_req_valid : cci_mem_rd_req_valid;
assign cci_mem_req_addr  = cci_mem_req_rw ? cci_mem_wr_req_addr : cci_mem_rd_req_addr;
assign cci_mem_req_data  = cci_rdq_dout[CCI_RD_QUEUE_DATAW-1:CCI_ADDR_WIDTH];
assign cci_mem_req_tag   = cci_mem_req_rw ? cci_mem_wr_req_ctr : cci_mem_rd_req_ctr;

// Vortex /////////////////////////////////////////////////////////////////////

wire                          vx_dcr_wr_valid = (STATE_DCR_WRITE == state);
wire [`VX_DCR_ADDR_WIDTH-1:0] vx_dcr_wr_addr  = cmd_dcr_addr;
wire [`VX_DCR_DATA_WIDTH-1:0] vx_dcr_wr_data  = cmd_dcr_data;

Vortex vortex (
  `SCOPE_BIND_afu_vortex

  .clk            (clk),
  .reset          (reset || vx_reset),

  // Memory request 
  .mem_req_valid  (vx_mem_req_valid),
  .mem_req_rw     (vx_mem_req_rw),
  .mem_req_byteen (vx_mem_req_byteen),
  .mem_req_addr   (vx_mem_req_addr),
  .mem_req_data   (vx_mem_req_data),
  .mem_req_tag    (vx_mem_req_tag),
  .mem_req_ready  (vx_mem_req_ready),

  // Memory response  
  .mem_rsp_valid  (vx_mem_rsp_valid),
  .mem_rsp_data   (vx_mem_rsp_data),
  .mem_rsp_tag    (vx_mem_rsp_tag),
  .mem_rsp_ready  (vx_mem_rsp_ready),

  // DCR write request
  .dcr_wr_valid   (vx_dcr_wr_valid),
  .dcr_wr_addr    (vx_dcr_wr_addr),
  .dcr_wr_data    (vx_dcr_wr_data),
 
  // Status
  .busy           (vx_busy)
);

assign cmd_run_done = !vx_busy;

// COUT HANDLING //////////////////////////////////////////////////////////////

wire [COUT_TID_WIDTH-1:0] cout_tid;

VX_onehot_encoder #(
  .N (`VX_MEM_BYTEEN_WIDTH)
) cout_tid_enc (
  .data_in  (vx_mem_req_byteen),
  .data_out (cout_tid),
  `UNUSED_PIN (valid_out)
);

assign vx_mem_is_cout = (vx_mem_req_addr == `VX_MEM_ADDR_WIDTH'(`IO_COUT_ADDR >> (32 - `VX_MEM_ADDR_WIDTH)));

assign vx_mem_req_ready = vx_mem_is_cout ? ~cout_q_full : vx_mem_req_ready_qual;

wire [`VX_MEM_BYTEEN_WIDTH-1:0][7:0] vx_mem_req_data_m = vx_mem_req_data;
wire [7:0] cout_char = vx_mem_req_data_m[cout_tid];

wire cout_q_push = vx_mem_req_valid && vx_mem_is_cout && vx_running && ~cout_q_full;

wire cout_q_pop = cp2af_sRxPort.c0.mmioRdValid 
               && (mmio_hdr.address == MMIO_STATUS)
               && ~cout_q_empty;

VX_fifo_queue #(
  .DATAW (COUT_QUEUE_DATAW),
  .SIZE  (COUT_QUEUE_SIZE)
) cout_queue (
  .clk      (clk),
  .reset    (reset),
  .push     (cout_q_push),
  .pop      (cout_q_pop),
  .data_in  ({cout_tid, cout_char}),
  .data_out (cout_q_dout),
  .empty    (cout_q_empty),
  .full     (cout_q_full),
  `UNUSED_PIN (alm_empty),
  `UNUSED_PIN (alm_full),
  `UNUSED_PIN (size)
);

// SCOPE //////////////////////////////////////////////////////////////////////

`ifdef SCOPE

`SCOPE_ASSIGN (cmd_type, cmd_type);
`SCOPE_ASSIGN (state, state);
`SCOPE_ASSIGN (cci_sRxPort_c0_mmioRdValid, cp2af_sRxPort.c0.mmioRdValid);
`SCOPE_ASSIGN (cci_sRxPort_c0_mmioWrValid, cp2af_sRxPort.c0.mmioWrValid);
`SCOPE_ASSIGN (mmio_hdr_address, mmio_hdr.address);
`SCOPE_ASSIGN (mmio_hdr_length, mmio_hdr.length);
`SCOPE_ASSIGN (cci_sRxPort_c0_hdr_mdata, cp2af_sRxPort.c0.hdr.mdata);
`SCOPE_ASSIGN (cci_sRxPort_c0_rspValid, cp2af_sRxPort.c0.rspValid);
`SCOPE_ASSIGN (cci_sRxPort_c1_rspValid, cp2af_sRxPort.c1.rspValid);            
`SCOPE_ASSIGN (cci_sTxPort_c0_valid, af2cp_sTxPort.c0.valid);
`SCOPE_ASSIGN (cci_sTxPort_c0_hdr_address, af2cp_sTxPort.c0.hdr.address);
`SCOPE_ASSIGN (cci_sTxPort_c0_hdr_mdata, af2cp_sTxPort.c0.hdr.mdata);
`SCOPE_ASSIGN (cci_sTxPort_c1_valid, af2cp_sTxPort.c1.valid);
`SCOPE_ASSIGN (cci_sTxPort_c1_hdr_address, af2cp_sTxPort.c1.hdr.address);
`SCOPE_ASSIGN (cci_sTxPort_c2_mmioRdValid, af2cp_sTxPort.c2.mmioRdValid);
`SCOPE_ASSIGN (cci_sRxPort_c0TxAlmFull, cp2af_sRxPort.c0TxAlmFull);
`SCOPE_ASSIGN (cci_sRxPort_c1TxAlmFull, cp2af_sRxPort.c1TxAlmFull);
`SCOPE_ASSIGN (avs_address, avs_address[0]);
`SCOPE_ASSIGN (avs_waitrequest, avs_waitrequest[0]);
`SCOPE_ASSIGN (avs_write_fire, avs_write[0] && !avs_waitrequest[0]);
`SCOPE_ASSIGN (avs_read_fire, avs_read[0] && !avs_waitrequest[0]);
`SCOPE_ASSIGN (avs_byteenable, avs_byteenable[0]);
`SCOPE_ASSIGN (avs_burstcount, avs_burstcount[0]);
`SCOPE_ASSIGN (avs_readdatavalid, avs_readdatavalid[0]);
`SCOPE_ASSIGN (cci_mem_rd_req_ctr, cci_mem_rd_req_ctr);
`SCOPE_ASSIGN (cci_mem_wr_req_ctr, cci_mem_wr_req_ctr);
`SCOPE_ASSIGN (cci_rd_req_ctr, cci_rd_req_ctr);
`SCOPE_ASSIGN (cci_rd_rsp_ctr, cci_rd_rsp_ctr);
`SCOPE_ASSIGN (cci_wr_req_ctr, cci_wr_req_ctr);
`SCOPE_ASSIGN (cci_wr_req_fire, cci_wr_req_fire);
`SCOPE_ASSIGN (cci_wr_rsp_fire, cci_wr_rsp_fire);
`SCOPE_ASSIGN (cci_rd_req_fire, cci_rd_req_fire);
`SCOPE_ASSIGN (cci_rd_rsp_fire, cci_rd_rsp_fire);
`SCOPE_ASSIGN (cci_pending_reads_full, cci_pending_reads_full);
`SCOPE_ASSIGN (cci_pending_writes_empty, cci_pending_writes_empty);
`SCOPE_ASSIGN (cci_pending_writes_full, cci_pending_writes_full);
`SCOPE_ASSIGN (afu_mem_req_fire, (mem_req_if.valid && mem_req_if.ready));
`SCOPE_ASSIGN (afu_mem_req_addr, mem_req_if.addr);
`SCOPE_ASSIGN (afu_mem_rsp_fire, (mem_rsp_if.valid && mem_rsp_if.ready));

wire scope_changed = `SCOPE_TRIGGER;

`RESET_RELAY (scope_reset, reset);

VX_scope #(
  .DATAW ($bits({`SCOPE_DATA_LIST,`SCOPE_UPDATE_LIST})),
  .BUSW  (64),
  .SIZE  (`SCOPE_SIZE),
  .UPDW  ($bits({`SCOPE_UPDATE_LIST}))
) scope (
  .clk      (clk),
  .reset    (scope_reset),
  .start    (1'b0),
  .stop     (1'b0),
  .changed  (scope_changed),
  .data_in  ({`SCOPE_DATA_LIST,`SCOPE_UPDATE_LIST}),
  .bus_in   (cmd_scope_wdata),
  .bus_out  (cmd_scope_rdata),
  .bus_read (cmd_scope_read),
  .bus_write(cmd_scope_write)
);

`else
  `UNUSED_PARAM (MMIO_SCOPE_READ)
  `UNUSED_PARAM (MMIO_SCOPE_WRITE)
`endif

endmodule
