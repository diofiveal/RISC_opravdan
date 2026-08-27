`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module icache_datapath #(
    parameter int unsigned ICACHE_ADDR_WIDTH,
    parameter int unsigned ICACHE_DATA_WIDTH,
    parameter int unsigned ICACHE_WORD_BYTES,
    parameter int unsigned ICACHE_LINE_WORDS,
    parameter int unsigned ICACHE_LINES,
    parameter int unsigned ICACHE_OFFSET_BITS,
    parameter int unsigned ICACHE_WORD_OFFSET_BITS,
    parameter int unsigned ICACHE_INDEX_BITS,
    parameter int unsigned ICACHE_TAG_BITS,
    parameter int unsigned ICACHE_REFILL_CNT_WIDTH,
    parameter int unsigned ICACHE_BYTE_OFFSET_BITS

) (
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic [ICACHE_ADDR_WIDTH-1:0]  router_addr_i,
    input  logic [ICACHE_DATA_WIDTH-1:0]  memory_rdata_i,

    // FSM controls
    input  logic                          req_latch_i,
    input  logic                          lookup_data_latch_i,
    input  logic                          refill_start_i,
    input  logic                          refill_word_we_i,
    input  logic                          refill_cnt_inc_i,
    input  logic                          line_commit_i,

    // FSM status
    output logic                          lookup_hit_o,
    output logic                          refill_last_word_o,

    // External datapath results
    output logic [ICACHE_ADDR_WIDTH-1:0]  refill_addr_o,
    output logic [ICACHE_DATA_WIDTH-1:0]  response_rdata_o
);
    localparam logic [ICACHE_REFILL_CNT_WIDTH-1:0] REFILL_LAST_CNT = ICACHE_REFILL_CNT_WIDTH'(ICACHE_LINE_WORDS - 1);
    
    logic [ICACHE_LINE_WORDS-1:0][ICACHE_DATA_WIDTH-1:0] data_array [0:ICACHE_LINES-1];
    logic [ICACHE_TAG_BITS-1:0] tag_array [0:ICACHE_LINES-1];
    logic [ICACHE_LINES-1:0] valid_array;

    // Saved request registers
    logic [ICACHE_ADDR_WIDTH-1:0]        req_addr_q;
    logic [ICACHE_TAG_BITS-1:0]          req_tag_q;
    logic [ICACHE_INDEX_BITS-1:0]        req_index_q;
    logic [ICACHE_WORD_OFFSET_BITS-1:0]  req_word_offset_q;

    // Refill control
    logic [ICACHE_REFILL_CNT_WIDTH-1:0]  refill_cnt_q;
    logic [ICACHE_ADDR_WIDTH-1:0]        refill_base_addr;
    logic [ICACHE_DATA_WIDTH-1:0]        response_rdata_q;
    logic [ICACHE_ADDR_WIDTH-1:0]        refill_word_offset_addr;

    logic [ICACHE_TAG_BITS-1:0]         req_tag;
    logic [ICACHE_INDEX_BITS-1:0]       req_index;
    logic [ICACHE_WORD_OFFSET_BITS-1:0] req_word_offset;
    logic [ICACHE_DATA_WIDTH-1:0]       lookup_data;

    assign req_tag =
        router_addr_i[
            ICACHE_ADDR_WIDTH-1:
            ICACHE_INDEX_BITS + ICACHE_OFFSET_BITS
        ];

    assign req_index =
        router_addr_i[
            ICACHE_INDEX_BITS + ICACHE_OFFSET_BITS - 1:
            ICACHE_OFFSET_BITS
        ];

    assign req_word_offset =
        router_addr_i[
            ICACHE_OFFSET_BITS-1:
            ICACHE_BYTE_OFFSET_BITS
        ];

    assign refill_base_addr = {
        req_addr_q[ICACHE_ADDR_WIDTH-1:ICACHE_OFFSET_BITS], 
        {ICACHE_OFFSET_BITS{1'b0}}
    };

    assign refill_word_offset_addr =
        {{(ICACHE_ADDR_WIDTH - ICACHE_REFILL_CNT_WIDTH){1'b0}},
        refill_cnt_q} << ICACHE_BYTE_OFFSET_BITS;

    assign refill_addr_o = refill_base_addr + refill_word_offset_addr;

    assign refill_last_word_o = (refill_cnt_q == REFILL_LAST_CNT);

    assign response_rdata_o = response_rdata_q;

    assign lookup_hit_o = valid_array[req_index_q] && (tag_array[req_index_q] == req_tag_q);

    assign lookup_data = data_array[req_index_q][req_word_offset_q];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_addr_q        <= '0;
            req_tag_q         <= '0;
            req_index_q       <= '0;
            req_word_offset_q <= '0;

            refill_cnt_q     <= '0;
            response_rdata_q <= '0;
            valid_array      <= '0;
        end else begin
            if (req_latch_i) begin
                req_addr_q        <= router_addr_i;
                req_tag_q         <= req_tag;
                req_index_q       <= req_index;
                req_word_offset_q <= req_word_offset;
                response_rdata_q  <= '0;
            end

            if (lookup_data_latch_i) begin
                response_rdata_q <= lookup_data;
            end

            if (refill_start_i) begin
                refill_cnt_q <= '0;
                valid_array[req_index_q] <= 1'b0;
            end else if (refill_cnt_inc_i) begin
                refill_cnt_q <= refill_cnt_q + 1'b1;
            end

            if (refill_word_we_i) begin
            data_array[req_index_q][refill_cnt_q] <= memory_rdata_i;

                if (req_word_offset_q == refill_cnt_q)
                    response_rdata_q <= memory_rdata_i;
            end

            if (line_commit_i) begin
                tag_array[req_index_q]   <= req_tag_q;
                valid_array[req_index_q] <= 1'b1;
            end
        end
    end

endmodule