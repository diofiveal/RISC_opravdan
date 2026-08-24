`include "scr1_memif.svh"
`include "scr1_arch_description.svh"


module victim_cache #(
    parameter int unsigned ICACHE_DATA_WIDTH,
    parameter int unsigned ICACHE_LINE_WORDS,
    parameter int unsigned ICACHE_WORD_OFFSET_BITS,
    parameter int unsigned ICACHE_INDEX_BITS,
    parameter int unsigned ICACHE_TAG_BITS,

    parameter int unsigned VICTIM_LINES = 4,
    parameter int unsigned VICTIM_ENTRY_BITS =
        (VICTIM_LINES > 1) ? $clog2(VICTIM_LINES) : 1
) (
    input logic clk,
    input logic rst_n,

    //Lookup
    input logic                                            victim_lookup_en_i,
    input logic [ICACHE_TAG_BITS-1:0]                      victim_lookup_tag_i,
    input logic [ICACHE_INDEX_BITS-1:0]                    victim_lookup_index_i,
    input logic [ICACHE_WORD_OFFSET_BITS-1:0]              victim_lookup_word_offset_i,
    output logic                                           victim_lookup_hit_o,
    output logic [VICTIM_ENTRY_BITS-1:0]                   victim_lookup_entry_o,
    output logic [ICACHE_DATA_WIDTH-1:0]                   victim_lookup_data_o,
    output logic [ICACHE_LINE_WORDS*ICACHE_DATA_WIDTH-1:0] victim_lookup_line_o,

    //write victim line
    input logic                                             victim_write_en_i,
    input logic [VICTIM_ENTRY_BITS-1:0]                     victim_write_entry_i,
    input logic [ICACHE_TAG_BITS-1:0]                       victim_write_tag_i,
    input logic [ICACHE_INDEX_BITS-1:0]                     victim_write_index_i,
    input logic [ICACHE_LINE_WORDS*ICACHE_DATA_WIDTH-1:0]   victim_write_line_i,

    //invalidate victim entry
    input logic                                             victim_invalidate_en_i,
    input logic [VICTIM_ENTRY_BITS-1:0]                     victim_invalidate_entry_i

);
    localparam int unsigned VICTIM_TAG_BITS = ICACHE_TAG_BITS + ICACHE_INDEX_BITS;

    //storage

    logic [VICTIM_LINES-1:0]      valid_array;

    logic [VICTIM_TAG_BITS-1:0]   tag_array [0:VICTIM_LINES-1];

    logic [ICACHE_DATA_WIDTH-1:0] data_array [0:VICTIM_LINES-1] [0:ICACHE_LINE_WORDS-1];

    
    logic [VICTIM_LINES-1:0] hit_array;
    logic [VICTIM_TAG_BITS-1:0] req_victim_tag;

    assign req_victim_tag = {victim_lookup_tag_i, victim_lookup_index_i};

    always_comb begin

        hit_array             = '0;
        victim_lookup_hit_o   = 1'b0;
        victim_lookup_entry_o = '0;
        victim_lookup_data_o  = '0;
        victim_lookup_line_o  = '0;

        if (victim_lookup_en_i) begin

            // Fully-associative tag lookup
            for (int i = 0; i < VICTIM_LINES; i++) begin
                hit_array[i] = valid_array[i]&& (tag_array[i] == req_victim_tag);
            end

        // Priority encoder: choose the first matching entry
            for (int i = 0; i < VICTIM_LINES; i++) begin

                if (hit_array[i] && !victim_lookup_hit_o) begin

                    victim_lookup_hit_o   = 1'b1;
                    victim_lookup_entry_o = VICTIM_ENTRY_BITS'(i);

                    victim_lookup_data_o = data_array[i][victim_lookup_word_offset_i];

                    for (int w = 0; w < ICACHE_LINE_WORDS; w++) begin
                        victim_lookup_line_o[w*ICACHE_DATA_WIDTH+: ICACHE_DATA_WIDTH] = data_array[i][w];
                    end

                end
            end

        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin

            valid_array <= '0;

        end else begin

            // Invalidate existing victim entry
            if (victim_invalidate_en_i) begin
                valid_array[victim_invalidate_entry_i] <= 1'b0;
            end

            // Write a complete cache line into victim entry
            if (victim_write_en_i) begin

                valid_array[victim_write_entry_i] <= 1'b1;

                tag_array[victim_write_entry_i] <= {victim_write_tag_i,victim_write_index_i};

                for (int w = 0; w < ICACHE_LINE_WORDS; w++) begin
                    data_array[victim_write_entry_i][w]
                        <= victim_write_line_i[w*ICACHE_DATA_WIDTH +: ICACHE_DATA_WIDTH];
                end
            end

        end
    end
    
endmodule