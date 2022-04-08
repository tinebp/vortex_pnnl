`ifndef VX_CACHE_DEFINE_VH
`define VX_CACHE_DEFINE_VH

`include "VX_platform.vh"

// cache request identifier
`define DBG_CACHE_REQ_IDW       `UP(REQ_DBG_IDW)

`define REQ_SEL_BITS            `LOG2UP(NUM_REQS)

//                                tag              valid  tid             word_sel              
`define MSHR_DATA_WIDTH         ((CORE_TAG_WIDTH + 1 +    `REQ_SEL_BITS + `UP(`WORD_SEL_BITS)) * NUM_PORTS)

`define WORD_WIDTH              (8 * WORD_SIZE)

`define CACHE_LINE_WIDTH        (8 * CACHE_LINE_SIZE)

`define BANK_SIZE               (CACHE_SIZE / NUM_BANKS)

`define WAY_SEL_BITS            `CLOG2(NUM_WAYS)

`define LINES_PER_BANK          (`BANK_SIZE / (CACHE_LINE_SIZE * NUM_WAYS))
`define WORDS_PER_LINE          (CACHE_LINE_SIZE / WORD_SIZE)

`define WORD_ADDR_WIDTH         (32-`CLOG2(WORD_SIZE))
`define MEM_ADDR_WIDTH          (32-`CLOG2(CACHE_LINE_SIZE))
`define LINE_ADDR_WIDTH         (`MEM_ADDR_WIDTH-`CLOG2(NUM_BANKS))

// Word select
`define WORD_SEL_BITS           `CLOG2(`WORDS_PER_LINE)
`define WORD_SEL_ADDR_START     0
`define WORD_SEL_ADDR_END       (`WORD_SEL_ADDR_START+`WORD_SEL_BITS-1)

// Bank select
`define BANK_SEL_BITS           `CLOG2(NUM_BANKS)
`define BANK_SEL_ADDR_START     (1+`WORD_SEL_ADDR_END)
`define BANK_SEL_ADDR_END       (`BANK_SEL_ADDR_START+`BANK_SEL_BITS-1)

// Line select
`define LINE_SEL_BITS           `CLOG2(`LINES_PER_BANK)
`define LINE_SEL_ADDR_START     (1+`BANK_SEL_ADDR_END)
`define LINE_SEL_ADDR_END       (`LINE_SEL_ADDR_START+`LINE_SEL_BITS-1)

// Tag select
`define TAG_SEL_BITS            (`WORD_ADDR_WIDTH-1-`LINE_SEL_ADDR_END)
`define TAG_SEL_ADDR_START      (1+`LINE_SEL_ADDR_END)
`define TAG_SEL_ADDR_END        (`WORD_ADDR_WIDTH-1)

`define LINE_TAG_ADDR(x)        x[`LINE_ADDR_WIDTH-1 : `LINE_SEL_BITS]

`define ASSIGN_REQ_DBG_ID(dst, tag) \
    if (REQ_DBG_IDW > 0) begin      \
        assign dst = tag[CORE_TAG_WIDTH-1 : (CORE_TAG_WIDTH-REQ_DBG_IDW)]; \
    end else begin \
        assign dst = 0; \
    end

///////////////////////////////////////////////////////////////////////////////

`define LINE_TO_MEM_ADDR(x, i)  {x, `BANK_SEL_BITS'(i)}

`define MEM_ADDR_TO_BANK_ID(x)  x[0 +: `BANK_SEL_BITS]

`define MEM_TAG_TO_REQ_ID(x)    x[MSHR_ADDR_WIDTH-1:0]

`define MEM_TAG_TO_BANK_ID(x)   x[MSHR_ADDR_WIDTH +: `BANK_SEL_BITS]

`define LINE_TO_BYTE_ADDR(x, i) {x, (32-$bits(x))'(i << (32-$bits(x)-`BANK_SEL_BITS))}

`define TO_FULL_ADDR(x)         {x, (32-$bits(x))'(0)}

`endif
