`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module scr1_icache #(
    parameter int unsigned ICACHE_SIZE_BYTES = 4096,
    parameter int unsigned ICACHE_LINE_BYTES = 16,
    parameter int unsigned ICACHE_WAYS       = 1
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // IMEM router interface
    output logic                         router_req_ack_o,
    input  logic                         router_req_i,
    input  type_scr1_mem_cmd_e           router_cmd_i,
    input  logic [`SCR1_IMEM_AWIDTH-1:0] router_addr_i,
    output logic [`SCR1_IMEM_DWIDTH-1:0] router_rdata_o,
    output type_scr1_mem_resp_e          router_resp_o,

    // AHB / AXI bridge interface
    input  logic                         memory_req_ack_i,
    output logic                         memory_req_o,
    output type_scr1_mem_cmd_e           memory_cmd_o,
    output logic [`SCR1_IMEM_AWIDTH-1:0] memory_addr_o,
    input  logic [`SCR1_IMEM_DWIDTH-1:0] memory_rdata_i,
    input  type_scr1_mem_resp_e          memory_resp_i
);

    localparam int unsigned ICACHE_ADDR_WIDTH = `SCR1_IMEM_AWIDTH;
    localparam int unsigned ICACHE_DATA_WIDTH = `SCR1_IMEM_DWIDTH;
    localparam int unsigned ICACHE_WORD_BYTES = ICACHE_DATA_WIDTH / 8;
    localparam int unsigned ICACHE_LINE_WORDS =
        ICACHE_LINE_BYTES / ICACHE_WORD_BYTES;
    localparam int unsigned ICACHE_LINES =
        ICACHE_SIZE_BYTES / ICACHE_LINE_BYTES;
    localparam int unsigned ICACHE_OFFSET_BITS =
        $clog2(ICACHE_LINE_BYTES);
    localparam int unsigned ICACHE_WORD_OFFSET_BITS =
        (ICACHE_LINE_WORDS > 1) ? $clog2(ICACHE_LINE_WORDS) : 1;
    localparam int unsigned ICACHE_INDEX_BITS =
        (ICACHE_LINES > 1) ? $clog2(ICACHE_LINES) : 1;
    localparam int unsigned ICACHE_TAG_BITS =
        ICACHE_ADDR_WIDTH - ICACHE_OFFSET_BITS - ICACHE_INDEX_BITS;
    localparam int unsigned ICACHE_REFILL_CNT_WIDTH =
        (ICACHE_LINE_WORDS > 1) ? $clog2(ICACHE_LINE_WORDS) : 1;
    localparam int unsigned ICACHE_BYTE_OFFSET_BITS =
        (ICACHE_WORD_BYTES > 1) ? $clog2(ICACHE_WORD_BYTES) : 1;

    // ICACHE_WAYS is kept for top-level compatibility. The current cache is
    // still direct mapped; this refactor changes structure, not associativity.

    logic                                     cache_lookup_en;
    logic [ICACHE_INDEX_BITS-1:0]             cache_lookup_index;
    logic [ICACHE_WORD_OFFSET_BITS-1:0]       cache_lookup_word_offset;
    logic [ICACHE_TAG_BITS-1:0]               cache_lookup_tag;
    logic [ICACHE_DATA_WIDTH-1:0]             cache_lookup_data;
    logic                                     cache_lookup_valid;

    logic                                     cache_line_invalidate;
    logic [ICACHE_INDEX_BITS-1:0]             cache_line_invalidate_index;

    logic                                     cache_refill_we;
    logic [ICACHE_INDEX_BITS-1:0]             cache_refill_index;
    logic [ICACHE_WORD_OFFSET_BITS-1:0]       cache_refill_word_offset;
    logic [ICACHE_DATA_WIDTH-1:0]             cache_refill_data;

    logic                                     cache_line_commit;
    logic [ICACHE_INDEX_BITS-1:0]             cache_line_commit_index;
    logic [ICACHE_TAG_BITS-1:0]               cache_line_commit_tag;

    logic                                     perf_req_accept;
    logic                                     perf_lookup_event;
    logic                                     perf_lookup_hit;
    logic                                     perf_refill_word;

    icache #(
        .ICACHE_DATA_WIDTH        (ICACHE_DATA_WIDTH),
        .ICACHE_LINE_WORDS        (ICACHE_LINE_WORDS),
        .ICACHE_LINES             (ICACHE_LINES),
        .ICACHE_WORD_OFFSET_BITS  (ICACHE_WORD_OFFSET_BITS),
        .ICACHE_INDEX_BITS        (ICACHE_INDEX_BITS),
        .ICACHE_TAG_BITS          (ICACHE_TAG_BITS)
    ) i_icache (
        .clk                         (clk),
        .rst_n                       (rst_n),

        .lookup_en_i                 (cache_lookup_en),
        .lookup_index_i              (cache_lookup_index),
        .lookup_word_offset_i        (cache_lookup_word_offset),
        .lookup_tag_o                (cache_lookup_tag),
        .lookup_data_o               (cache_lookup_data),
        .lookup_valid_o              (cache_lookup_valid),

        .line_invalidate_i           (cache_line_invalidate),
        .line_invalidate_index_i     (cache_line_invalidate_index),

        .refill_we_i                 (cache_refill_we),
        .refill_index_i              (cache_refill_index),
        .refill_word_offset_i        (cache_refill_word_offset),
        .refill_data_i               (cache_refill_data),

        .line_commit_i               (cache_line_commit),
        .line_commit_index_i         (cache_line_commit_index),
        .line_commit_tag_i           (cache_line_commit_tag)
    );

    icache_controller #(
        .ICACHE_ADDR_WIDTH        (ICACHE_ADDR_WIDTH),
        .ICACHE_DATA_WIDTH        (ICACHE_DATA_WIDTH),
        .ICACHE_LINE_WORDS        (ICACHE_LINE_WORDS),
        .ICACHE_OFFSET_BITS       (ICACHE_OFFSET_BITS),
        .ICACHE_WORD_OFFSET_BITS  (ICACHE_WORD_OFFSET_BITS),
        .ICACHE_INDEX_BITS        (ICACHE_INDEX_BITS),
        .ICACHE_TAG_BITS          (ICACHE_TAG_BITS),
        .ICACHE_REFILL_CNT_WIDTH  (ICACHE_REFILL_CNT_WIDTH),
        .ICACHE_BYTE_OFFSET_BITS  (ICACHE_BYTE_OFFSET_BITS)
    ) i_icache_controller (
        .clk                         (clk),
        .rst_n                       (rst_n),

        .router_req_i                (router_req_i),
        .router_cmd_i                (router_cmd_i),
        .router_addr_i               (router_addr_i),
        .router_req_ack_o            (router_req_ack_o),
        .router_rdata_o              (router_rdata_o),
        .router_resp_o               (router_resp_o),

        .memory_req_o                (memory_req_o),
        .memory_cmd_o                (memory_cmd_o),
        .memory_addr_o               (memory_addr_o),
        .memory_req_ack_i            (memory_req_ack_i),
        .memory_rdata_i              (memory_rdata_i),
        .memory_resp_i               (memory_resp_i),

        .cache_lookup_tag_i          (cache_lookup_tag),
        .cache_lookup_data_i         (cache_lookup_data),
        .cache_lookup_valid_i        (cache_lookup_valid),

        .cache_lookup_en_o           (cache_lookup_en),
        .cache_lookup_index_o        (cache_lookup_index),
        .cache_lookup_word_offset_o  (cache_lookup_word_offset),

        .cache_line_invalidate_o       (cache_line_invalidate),
        .cache_line_invalidate_index_o (cache_line_invalidate_index),

        .cache_refill_we_o           (cache_refill_we),
        .cache_refill_index_o        (cache_refill_index),
        .cache_refill_word_offset_o  (cache_refill_word_offset),
        .cache_refill_data_o         (cache_refill_data),

        .cache_line_commit_o         (cache_line_commit),
        .cache_line_commit_index_o   (cache_line_commit_index),
        .cache_line_commit_tag_o     (cache_line_commit_tag),

        .perf_req_accept_o           (perf_req_accept),
        .perf_lookup_event_o         (perf_lookup_event),
        .perf_lookup_hit_o           (perf_lookup_hit),
        .perf_refill_word_o          (perf_refill_word)
    );

`ifdef SCR1_TRGT_SIMULATION
    logic [63:0] perf_accesses;
    logic [63:0] perf_hits;
    logic [63:0] perf_misses;
    logic [63:0] perf_refill_words;
    logic [63:0] perf_stall_cycles;

    logic perf_request_active_q;
    logic perf_router_response;

    assign perf_router_response =
        (router_resp_o == SCR1_MEM_RESP_RDY_OK)
        || (router_resp_o == SCR1_MEM_RESP_RDY_ER);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_accesses         <= 64'd0;
            perf_hits             <= 64'd0;
            perf_misses           <= 64'd0;
            perf_refill_words     <= 64'd0;
            perf_stall_cycles     <= 64'd0;
            perf_request_active_q <= 1'b0;
        end else begin
            if (perf_req_accept) begin
                perf_accesses <= perf_accesses + 64'd1;
            end

            if (perf_lookup_event) begin
                if (perf_lookup_hit) begin
                    perf_hits <= perf_hits + 64'd1;
                end else begin
                    perf_misses <= perf_misses + 64'd1;
                end
            end

            if (perf_refill_word) begin
                perf_refill_words <= perf_refill_words + 64'd1;
            end

            if (perf_request_active_q) begin
                perf_stall_cycles <= perf_stall_cycles + 64'd1;
            end

            if (perf_req_accept) begin
                perf_request_active_q <= 1'b1;
            end

            if (perf_router_response) begin
                perf_request_active_q <= 1'b0;
            end
        end
    end

    final begin
        $display("");
        $display("========================================");
        $display(" I-cache counters");
        $display("========================================");
        $display("accesses     : %0d", perf_accesses);
        $display("hits         : %0d", perf_hits);
        $display("misses       : %0d", perf_misses);
        $display("refill words : %0d", perf_refill_words);
        $display("stall cycles : %0d", perf_stall_cycles);
        $display("========================================");
    end
`endif

endmodule
