`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module scr1_dcache #(
    parameter int unsigned DCACHE_SIZE_BYTES = 2048,
    parameter int unsigned DCACHE_LINE_BYTES = 8,
    parameter int unsigned DCACHE_WAYS       = 1
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // DMEM router interface
    input  logic                         router_req_i,
    input  type_scr1_mem_cmd_e           router_cmd_i,
    input  type_scr1_mem_width_e         router_width_i,
    input  logic [`SCR1_DMEM_AWIDTH-1:0] router_addr_i,
    input  logic [`SCR1_DMEM_DWIDTH-1:0] router_wdata_i,
    output logic                         router_req_ack_o,
    output logic [`SCR1_DMEM_DWIDTH-1:0] router_rdata_o,
    output type_scr1_mem_resp_e          router_resp_o,

    // AHB / AXI bridge interface
    output logic                         memory_req_o,
    output type_scr1_mem_cmd_e           memory_cmd_o,
    output type_scr1_mem_width_e         memory_width_o,
    output logic [`SCR1_DMEM_AWIDTH-1:0] memory_addr_o,
    output logic [`SCR1_DMEM_DWIDTH-1:0] memory_wdata_o,
    input  logic                         memory_req_ack_i,
    input  logic [`SCR1_DMEM_DWIDTH-1:0] memory_rdata_i,
    input  type_scr1_mem_resp_e          memory_resp_i
);

    localparam int unsigned DCACHE_ADDR_WIDTH = `SCR1_DMEM_AWIDTH;
    localparam int unsigned DCACHE_DATA_WIDTH = `SCR1_DMEM_DWIDTH;
    localparam int unsigned DCACHE_WORD_BYTES = DCACHE_DATA_WIDTH / 8;
    localparam int unsigned DCACHE_LINE_WORDS =
        DCACHE_LINE_BYTES / DCACHE_WORD_BYTES;
    localparam int unsigned DCACHE_LINES =
        DCACHE_SIZE_BYTES / DCACHE_LINE_BYTES;
    localparam int unsigned DCACHE_OFFSET_BITS =
        $clog2(DCACHE_LINE_BYTES);
    localparam int unsigned DCACHE_WORD_OFFSET_BITS =
        (DCACHE_LINE_WORDS > 1) ? $clog2(DCACHE_LINE_WORDS) : 1;
    localparam int unsigned DCACHE_INDEX_BITS =
        (DCACHE_LINES > 1) ? $clog2(DCACHE_LINES) : 1;
    localparam int unsigned DCACHE_TAG_BITS =
        DCACHE_ADDR_WIDTH - DCACHE_OFFSET_BITS - DCACHE_INDEX_BITS;
    localparam int unsigned DCACHE_REFILL_CNT_WIDTH =
        (DCACHE_LINE_WORDS > 1) ? $clog2(DCACHE_LINE_WORDS) : 1;
    localparam int unsigned DCACHE_BYTE_OFFSET_BITS =
        (DCACHE_WORD_BYTES > 1) ? $clog2(DCACHE_WORD_BYTES) : 1;

    // DCACHE_WAYS is intentionally kept in the public interface for
    // compatibility with the previous top. This refactor preserves the current
    // direct-mapped implementation; associativity is not changed here.

    // Controller <-> cache lookup
    logic                                     cache_lookup_en;
    logic [DCACHE_INDEX_BITS-1:0]             cache_lookup_index;
    logic [DCACHE_WORD_OFFSET_BITS-1:0]       cache_lookup_word_offset;
    logic [DCACHE_TAG_BITS-1:0]               cache_lookup_tag;
    logic [DCACHE_DATA_WIDTH-1:0]             cache_lookup_data;
    logic                                     cache_lookup_valid;

    // Controller -> cache update controls
    logic                                     cache_line_invalidate;
    logic [DCACHE_INDEX_BITS-1:0]             cache_line_invalidate_index;

    logic                                     cache_refill_we;
    logic [DCACHE_INDEX_BITS-1:0]             cache_refill_index;
    logic [DCACHE_WORD_OFFSET_BITS-1:0]       cache_refill_word_offset;
    logic [DCACHE_DATA_WIDTH-1:0]             cache_refill_data;

    logic                                     cache_line_commit;
    logic [DCACHE_INDEX_BITS-1:0]             cache_line_commit_index;
    logic [DCACHE_TAG_BITS-1:0]               cache_line_commit_tag;

    logic                                     cache_store_we;
    logic [DCACHE_INDEX_BITS-1:0]             cache_store_index;
    logic [DCACHE_WORD_OFFSET_BITS-1:0]       cache_store_word_offset;
    logic [DCACHE_DATA_WIDTH-1:0]             cache_store_data;

    // Controller monitoring events. They keep the existing top-level
    // simulation-counter names stable for testbenches that use hierarchy.
    logic                                     perf_req_accept;
    logic                                     perf_lookup_event;
    logic                                     perf_lookup_hit;
    logic                                     perf_req_is_store;
    logic                                     perf_refill_word;

    dcache #(
        .DCACHE_DATA_WIDTH        (DCACHE_DATA_WIDTH),
        .DCACHE_LINE_WORDS        (DCACHE_LINE_WORDS),
        .DCACHE_LINES             (DCACHE_LINES),
        .DCACHE_WORD_OFFSET_BITS  (DCACHE_WORD_OFFSET_BITS),
        .DCACHE_INDEX_BITS        (DCACHE_INDEX_BITS),
        .DCACHE_TAG_BITS          (DCACHE_TAG_BITS)
    ) i_dcache (
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
        .line_commit_tag_i           (cache_line_commit_tag),

        .store_we_i                  (cache_store_we),
        .store_index_i               (cache_store_index),
        .store_word_offset_i         (cache_store_word_offset),
        .store_data_i                (cache_store_data)
    );

    dcache_controller #(
        .DCACHE_ADDR_WIDTH        (DCACHE_ADDR_WIDTH),
        .DCACHE_DATA_WIDTH        (DCACHE_DATA_WIDTH),
        .DCACHE_WORD_BYTES        (DCACHE_WORD_BYTES),
        .DCACHE_LINE_WORDS        (DCACHE_LINE_WORDS),
        .DCACHE_OFFSET_BITS       (DCACHE_OFFSET_BITS),
        .DCACHE_WORD_OFFSET_BITS  (DCACHE_WORD_OFFSET_BITS),
        .DCACHE_INDEX_BITS        (DCACHE_INDEX_BITS),
        .DCACHE_TAG_BITS          (DCACHE_TAG_BITS),
        .DCACHE_REFILL_CNT_WIDTH  (DCACHE_REFILL_CNT_WIDTH),
        .DCACHE_BYTE_OFFSET_BITS  (DCACHE_BYTE_OFFSET_BITS)
    ) i_dcache_controller (
        .clk                         (clk),
        .rst_n                       (rst_n),

        .router_req_i                (router_req_i),
        .router_cmd_i                (router_cmd_i),
        .router_width_i              (router_width_i),
        .router_addr_i               (router_addr_i),
        .router_wdata_i              (router_wdata_i),
        .router_req_ack_o            (router_req_ack_o),
        .router_rdata_o              (router_rdata_o),
        .router_resp_o               (router_resp_o),

        .memory_req_o                (memory_req_o),
        .memory_cmd_o                (memory_cmd_o),
        .memory_width_o              (memory_width_o),
        .memory_addr_o               (memory_addr_o),
        .memory_wdata_o              (memory_wdata_o),
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

        .cache_store_we_o            (cache_store_we),
        .cache_store_index_o         (cache_store_index),
        .cache_store_word_offset_o   (cache_store_word_offset),
        .cache_store_data_o          (cache_store_data),

        .perf_req_accept_o           (perf_req_accept),
        .perf_lookup_event_o         (perf_lookup_event),
        .perf_lookup_hit_o           (perf_lookup_hit),
        .perf_req_is_store_o         (perf_req_is_store),
        .perf_refill_word_o          (perf_refill_word)
    );

`ifdef SCR1_TRGT_SIMULATION
    logic [63:0] perf_load_accesses;
    logic [63:0] perf_store_accesses;
    logic [63:0] perf_hits;
    logic [63:0] perf_misses;
    logic [63:0] perf_load_misses;
    logic [63:0] perf_store_misses;
    logic [63:0] perf_refill_words;
    logic [63:0] perf_stall_cycles;

    logic perf_request_active_q;
    logic perf_router_response;

    assign perf_router_response =
        (router_resp_o == SCR1_MEM_RESP_RDY_OK)
        || (router_resp_o == SCR1_MEM_RESP_RDY_ER);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_load_accesses    <= 64'd0;
            perf_store_accesses   <= 64'd0;
            perf_hits             <= 64'd0;
            perf_misses           <= 64'd0;
            perf_load_misses      <= 64'd0;
            perf_store_misses     <= 64'd0;
            perf_refill_words     <= 64'd0;
            perf_stall_cycles     <= 64'd0;
            perf_request_active_q <= 1'b0;
        end else begin
            if (perf_req_accept) begin
                if (router_cmd_i == SCR1_MEM_CMD_RD) begin
                    perf_load_accesses <= perf_load_accesses + 64'd1;
                end else if (router_cmd_i == SCR1_MEM_CMD_WR) begin
                    perf_store_accesses <= perf_store_accesses + 64'd1;
                end
            end

            if (perf_lookup_event) begin
                if (perf_lookup_hit) begin
                    perf_hits <= perf_hits + 64'd1;
                end else begin
                    perf_misses <= perf_misses + 64'd1;

                    if (perf_req_is_store) begin
                        perf_store_misses <= perf_store_misses + 64'd1;
                    end else begin
                        perf_load_misses <= perf_load_misses + 64'd1;
                    end
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
        $display(" D-cache counters");
        $display("========================================");
        $display("load accesses  : %0d", perf_load_accesses);
        $display("store accesses : %0d", perf_store_accesses);
        $display("total accesses : %0d",
                 perf_load_accesses + perf_store_accesses);
        $display("hits           : %0d", perf_hits);
        $display("misses         : %0d", perf_misses);
        $display("load misses    : %0d", perf_load_misses);
        $display("store misses   : %0d", perf_store_misses);
        $display("refill words   : %0d", perf_refill_words);
        $display("stall cycles   : %0d", perf_stall_cycles);
        $display("========================================");
    end
`endif

endmodule
