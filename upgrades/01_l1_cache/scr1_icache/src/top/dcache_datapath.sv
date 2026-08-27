`include "scr1_memif.svh"
`include "scr1_arch_description.svh"


module dcache_datapath #(
    parameter int unsigned DCACHE_ADDR_WIDTH,
    parameter int unsigned DCACHE_DATA_WIDTH,
    parameter int unsigned DCACHE_WORD_BYTES,
    parameter int unsigned DCACHE_LINE_WORDS,
    parameter int unsigned DCACHE_LINES,
    parameter int unsigned DCACHE_OFFSET_BITS,
    parameter int unsigned DCACHE_WORD_OFFSET_BITS,
    parameter int unsigned DCACHE_INDEX_BITS,
    parameter int unsigned DCACHE_TAG_BITS,
    parameter int unsigned DCACHE_REFILL_CNT_WIDTH,
    parameter int unsigned DCACHE_BYTE_OFFSET_BITS
) (
    input  logic                           clk,
    input  logic                           rst_n,

    // Current router request. Values are captured on req_latch_i.
    input  type_scr1_mem_cmd_e             router_cmd_i,
    input  type_scr1_mem_width_e           router_width_i,
    input  logic [DCACHE_ADDR_WIDTH-1:0]   router_addr_i,
    input  logic [DCACHE_DATA_WIDTH-1:0]   router_wdata_i,

    // Memory read data for line refill
    input  logic [DCACHE_DATA_WIDTH-1:0]   memory_rdata_i,

    // FSM controls
    input  logic                           req_latch_i,
    input  logic                           load_data_latch_i,
    input  logic                           refill_start_i,
    input  logic                           refill_word_we_i,
    input  logic                           refill_cnt_inc_i,
    input  logic                           line_commit_i,
    input  logic                           store_commit_i,

    // FSM status
    output logic                           req_valid_o,
    output logic                           req_is_store_o,
    output logic                           lookup_hit_o,
    output logic                           refill_last_word_o,

    // Refill transaction
    output logic [DCACHE_ADDR_WIDTH-1:0]   refill_addr_o,

    // Store transaction
    output logic [DCACHE_ADDR_WIDTH-1:0]   store_addr_o,
    output type_scr1_mem_width_e           store_width_o,
    output logic [DCACHE_DATA_WIDTH-1:0]   store_wdata_o,

    // Router response
    output logic [DCACHE_DATA_WIDTH-1:0]   response_rdata_o
);

    localparam logic [DCACHE_REFILL_CNT_WIDTH-1:0] REFILL_LAST_CNT =
        DCACHE_REFILL_CNT_WIDTH'(DCACHE_LINE_WORDS - 1);

    // Address decomposition of the current router request
    logic [DCACHE_TAG_BITS-1:0]          req_tag;
    logic [DCACHE_INDEX_BITS-1:0]        req_index;
    logic [DCACHE_WORD_OFFSET_BITS-1:0]  req_word_offset;
    logic [DCACHE_BYTE_OFFSET_BITS-1:0]  req_byte_offset;

    assign req_tag =
        router_addr_i[
            DCACHE_ADDR_WIDTH-1:
            DCACHE_INDEX_BITS + DCACHE_OFFSET_BITS
        ];

    assign req_index =
        router_addr_i[
            DCACHE_INDEX_BITS + DCACHE_OFFSET_BITS - 1:
            DCACHE_OFFSET_BITS
        ];

    assign req_word_offset =
        router_addr_i[
            DCACHE_OFFSET_BITS-1:
            DCACHE_BYTE_OFFSET_BITS
        ];

    assign req_byte_offset = router_addr_i[DCACHE_BYTE_OFFSET_BITS-1:0];

    // Direct-mapped cache arrays
    logic [DCACHE_LINE_WORDS-1:0][DCACHE_DATA_WIDTH-1:0] data_array [0:DCACHE_LINES-1];
    logic [DCACHE_TAG_BITS-1:0] tag_array [0:DCACHE_LINES-1];
    logic [DCACHE_LINES-1:0] valid_array;

    // Saved router request
    logic [DCACHE_ADDR_WIDTH-1:0]       req_addr_q;
    logic [DCACHE_TAG_BITS-1:0]         req_tag_q;
    logic [DCACHE_INDEX_BITS-1:0]       req_index_q;
    logic [DCACHE_WORD_OFFSET_BITS-1:0] req_word_offset_q;
    logic [DCACHE_BYTE_OFFSET_BITS-1:0] req_byte_offset_q;
    type_scr1_mem_cmd_e                 req_cmd_q;
    type_scr1_mem_width_e               req_width_q;
    logic [DCACHE_DATA_WIDTH-1:0]       req_wdata_q;

    // Lookup
    logic [DCACHE_DATA_WIDTH-1:0] cache_word;

    assign lookup_hit_o =
        valid_array[req_index_q]
        && (tag_array[req_index_q] == req_tag_q);

    assign cache_word = data_array[req_index_q][req_word_offset_q];

    assign req_is_store_o = (req_cmd_q == SCR1_MEM_CMD_WR);

    always_comb begin
        req_valid_o = 1'b0;

        if ((req_cmd_q == SCR1_MEM_CMD_RD)
            || (req_cmd_q == SCR1_MEM_CMD_WR)) begin
            case (req_width_q)
                SCR1_MEM_WIDTH_BYTE: begin
                    req_valid_o = 1'b1;
                end

                SCR1_MEM_WIDTH_HWORD: begin
                    req_valid_o = (req_addr_q[0] == 1'b0);
                end

                SCR1_MEM_WIDTH_WORD: begin
                    req_valid_o = (req_addr_q[1:0] == 2'b00);
                end

                default: begin
                    req_valid_o = 1'b0;
                end
            endcase
        end
    end

    // Refill address generation
    logic [DCACHE_REFILL_CNT_WIDTH-1:0] refill_cnt_q;
    logic [DCACHE_ADDR_WIDTH-1:0]       refill_base_addr;
    logic [DCACHE_ADDR_WIDTH-1:0]       refill_word_offset_addr;

    assign refill_base_addr = {
        req_addr_q[DCACHE_ADDR_WIDTH-1:DCACHE_OFFSET_BITS],
        {DCACHE_OFFSET_BITS{1'b0}}
    };

    assign refill_word_offset_addr =
        {{(DCACHE_ADDR_WIDTH - DCACHE_REFILL_CNT_WIDTH){1'b0}},
         refill_cnt_q}
        << DCACHE_BYTE_OFFSET_BITS;

    assign refill_addr_o =
        refill_base_addr + refill_word_offset_addr;

    assign refill_last_word_o =
        (refill_cnt_q == REFILL_LAST_CNT);

    assign store_addr_o  = req_addr_q;
    assign store_width_o = req_width_q;
    assign store_wdata_o = req_wdata_q;


    function automatic logic [DCACHE_DATA_WIDTH-1:0] extract_load_data (
        input logic [DCACHE_DATA_WIDTH-1:0]      word,
        input type_scr1_mem_width_e              width,
        input logic [DCACHE_BYTE_OFFSET_BITS-1:0] byte_offset
    );
        logic [DCACHE_DATA_WIDTH-1:0] result;
        begin
            result = '0;

            case (width)
                SCR1_MEM_WIDTH_BYTE: begin
                    result[7:0] = word[byte_offset * 8 +: 8];
                end

                SCR1_MEM_WIDTH_HWORD: begin
                    result[15:0] = word[byte_offset * 8 +: 16];
                end

                SCR1_MEM_WIDTH_WORD: begin
                    result = word;
                end

                default: begin
                    result = '0;
                end
            endcase

            return result;
        end
    endfunction

    function automatic logic [DCACHE_DATA_WIDTH-1:0] merge_store_data (
        input logic [DCACHE_DATA_WIDTH-1:0]      old_word,
        input logic [DCACHE_DATA_WIDTH-1:0]      store_data,
        input type_scr1_mem_width_e              width,
        input logic [DCACHE_BYTE_OFFSET_BITS-1:0] byte_offset
    );
        logic [DCACHE_DATA_WIDTH-1:0] result;
        begin
            result = old_word;

            case (width)
                SCR1_MEM_WIDTH_BYTE: begin
                    result[byte_offset * 8 +: 8] = store_data[7:0];
                end

                SCR1_MEM_WIDTH_HWORD: begin
                    result[byte_offset * 8 +: 16] = store_data[15:0];
                end

                SCR1_MEM_WIDTH_WORD: begin
                    result = store_data;
                end

                default: begin
                    result = old_word;
                end
            endcase

            return result;
        end
    endfunction

    logic [DCACHE_DATA_WIDTH-1:0] response_rdata_q;

    assign response_rdata_o = response_rdata_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_addr_q        <= '0;
            req_tag_q         <= '0;
            req_index_q       <= '0;
            req_word_offset_q <= '0;
            req_byte_offset_q <= '0;
            req_cmd_q         <= SCR1_MEM_CMD_RD;
            req_width_q       <= SCR1_MEM_WIDTH_WORD;
            req_wdata_q       <= '0;

            refill_cnt_q      <= '0;
            response_rdata_q  <= '0;
            valid_array       <= '0;
        end else begin
            if (req_latch_i) begin
                req_addr_q        <= router_addr_i;
                req_tag_q         <= req_tag;
                req_index_q       <= req_index;
                req_word_offset_q <= req_word_offset;
                req_byte_offset_q <= req_byte_offset;
                req_cmd_q         <= router_cmd_i;
                req_width_q       <= router_width_i;
                req_wdata_q       <= router_wdata_i;
                response_rdata_q  <= '0;
            end

            if (load_data_latch_i) begin
                response_rdata_q <= extract_load_data(
                    cache_word,
                    req_width_q,
                    req_byte_offset_q
                );
            end

            if (refill_start_i) begin
                refill_cnt_q <= '0;
                valid_array[req_index_q] <= 1'b0;
            end else if (refill_cnt_inc_i) begin
                refill_cnt_q <= refill_cnt_q + 1'b1;
            end

            if (refill_word_we_i) begin
                data_array[req_index_q][refill_cnt_q] <= memory_rdata_i;

                if ((req_cmd_q == SCR1_MEM_CMD_RD)
                    && (req_word_offset_q == refill_cnt_q)) begin
                    response_rdata_q <= extract_load_data(
                        memory_rdata_i,
                        req_width_q,
                        req_byte_offset_q
                    );
                end
            end

            if (line_commit_i) begin
                tag_array[req_index_q]   <= req_tag_q;
                valid_array[req_index_q] <= 1'b1;
            end
            if (store_commit_i) begin
                data_array[req_index_q][req_word_offset_q] <=
                    merge_store_data(
                        data_array[req_index_q][req_word_offset_q],
                        req_wdata_q,
                        req_width_q,
                        req_byte_offset_q
                    );
            end
        end
    end
endmodule
