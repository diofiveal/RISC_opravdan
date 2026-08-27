`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module dcache_controller #(
    parameter int unsigned DCACHE_ADDR_WIDTH,
    parameter int unsigned DCACHE_DATA_WIDTH,
    parameter int unsigned DCACHE_WORD_BYTES,
    parameter int unsigned DCACHE_LINE_WORDS,
    parameter int unsigned DCACHE_OFFSET_BITS,
    parameter int unsigned DCACHE_WORD_OFFSET_BITS,
    parameter int unsigned DCACHE_INDEX_BITS,
    parameter int unsigned DCACHE_TAG_BITS,
    parameter int unsigned DCACHE_REFILL_CNT_WIDTH,
    parameter int unsigned DCACHE_BYTE_OFFSET_BITS,
    parameter bit          DCACHE_NO_WRITE_ALLOCATE = 1'b1,
    parameter bit          DCACHE_AXI_BURST_ENABLE = 1'b1,
    parameter int unsigned DCACHE_MAX_READ_BURST_BEATS = 8
) (
    input  logic                                      clk,
    input  logic                                      rst_n,

    // DMEM router interface
    input  logic                                      router_req_i,
    input  type_scr1_mem_cmd_e                        router_cmd_i,
    input  type_scr1_mem_width_e                      router_width_i,
    input  logic [DCACHE_ADDR_WIDTH-1:0]              router_addr_i,
    input  logic [DCACHE_DATA_WIDTH-1:0]              router_wdata_i,
    output logic                                      router_req_ack_o,
    output logic [DCACHE_DATA_WIDTH-1:0]              router_rdata_o,
    output type_scr1_mem_resp_e                       router_resp_o,

    // Write-buffer interface. Cacheable STORE requests are enqueued here; the
    // buffer returns a local response while draining the store asynchronously.
    // READ/refill and uncached/MMIO requests keep normal memory semantics.
    output logic                                      memory_req_o,
    output type_scr1_mem_cmd_e                        memory_cmd_o,
    output type_scr1_mem_width_e                      memory_width_o,
    output logic [DCACHE_ADDR_WIDTH-1:0]              memory_addr_o,
    output logic [DCACHE_DATA_WIDTH-1:0]              memory_wdata_o,
    output logic [7:0]                                memory_burst_len_o,
    input  logic                                      memory_req_ack_i,
    input  logic                                      memory_rvalid_i,
    input  logic                                      memory_rlast_i,
    input  logic [DCACHE_DATA_WIDTH-1:0]              memory_rdata_i,
    input  type_scr1_mem_resp_e                       memory_resp_i,

    // Cache-array lookup results
    input  logic [DCACHE_TAG_BITS-1:0]                cache_lookup_tag_i,
    input  logic [DCACHE_DATA_WIDTH-1:0]              cache_lookup_data_i,
    input  logic                                      cache_lookup_valid_i,

    // Cache-array controls
    output logic                                      cache_lookup_en_o,
    output logic [DCACHE_INDEX_BITS-1:0]              cache_lookup_index_o,
    output logic [DCACHE_WORD_OFFSET_BITS-1:0]        cache_lookup_word_offset_o,

    output logic                                      cache_line_invalidate_o,
    output logic [DCACHE_INDEX_BITS-1:0]              cache_line_invalidate_index_o,

    output logic                                      cache_refill_we_o,
    output logic [DCACHE_INDEX_BITS-1:0]              cache_refill_index_o,
    output logic [DCACHE_WORD_OFFSET_BITS-1:0]        cache_refill_word_offset_o,
    output logic [DCACHE_DATA_WIDTH-1:0]              cache_refill_data_o,

    output logic                                      cache_line_commit_o,
    output logic [DCACHE_INDEX_BITS-1:0]              cache_line_commit_index_o,
    output logic [DCACHE_TAG_BITS-1:0]                cache_line_commit_tag_o,

    output logic                                      cache_store_we_o,
    output logic [DCACHE_INDEX_BITS-1:0]              cache_store_index_o,
    output logic [DCACHE_WORD_OFFSET_BITS-1:0]        cache_store_word_offset_o,
    output logic [DCACHE_DATA_WIDTH-1:0]              cache_store_data_o,

    // Monitoring events used by the existing simulation counters in top.
    output logic                                      perf_req_accept_o,
    output logic                                      perf_lookup_event_o,
    output logic                                      perf_lookup_hit_o,
    output logic                                      perf_req_is_store_o,
    output logic                                      perf_refill_word_o,
    output logic                                      perf_refill_burst_o,
    output logic                                      perf_burst_error_o
);

    localparam logic [DCACHE_REFILL_CNT_WIDTH-1:0] REFILL_LAST_CNT =
        DCACHE_REFILL_CNT_WIDTH'(DCACHE_LINE_WORDS - 1);

    typedef enum logic [3:0] {
        IDLE,
        LOOKUP,
        REFILL_REQ,
        REFILL_WAIT,
        STORE_REQ,
        STORE_WAIT,
        BYPASS_REQ,
        BYPASS_WAIT,
        ERROR
    } state_dcache_e;

    state_dcache_e state_q;
    state_dcache_e state_d;

    // Complete transaction context belongs to the controller. The cache module
    // only stores cache lines, tags and valid bits.
    logic [DCACHE_ADDR_WIDTH-1:0]              req_addr_q;
    logic [DCACHE_TAG_BITS-1:0]                req_tag_q;
    logic [DCACHE_INDEX_BITS-1:0]              req_index_q;
    logic [DCACHE_WORD_OFFSET_BITS-1:0]        req_word_offset_q;
    logic [DCACHE_BYTE_OFFSET_BITS-1:0]        req_byte_offset_q;
    type_scr1_mem_cmd_e                        req_cmd_q;
    type_scr1_mem_width_e                      req_width_q;
    logic [DCACHE_DATA_WIDTH-1:0]              req_wdata_q;
    logic                                      req_uncached_q;

    logic [DCACHE_REFILL_CNT_WIDTH-1:0]        refill_cnt_q;
    logic [DCACHE_DATA_WIDTH-1:0]              response_rdata_q;
    logic [DCACHE_DATA_WIDTH-1:0]              store_old_word_q;
    // One bit of transaction context is enough to distinguish a STORE hit
    // from a no-write-allocate STORE miss. Keeping this as a register avoids
    // adding tag/data RAM reads to the STORE completion path on FPGA.
    logic                                      store_update_cache_q;

    logic [DCACHE_TAG_BITS-1:0]                incoming_tag;
    logic                                      incoming_uncached;
    logic [DCACHE_INDEX_BITS-1:0]              incoming_index;
    logic [DCACHE_WORD_OFFSET_BITS-1:0]        incoming_word_offset;
    logic [DCACHE_BYTE_OFFSET_BITS-1:0]        incoming_byte_offset;

    logic                                      req_valid;
    logic                                      req_is_store;
    logic                                      lookup_hit;
    logic                                      refill_last_word;
    logic [DCACHE_ADDR_WIDTH-1:0]              refill_base_addr;
    logic [DCACHE_ADDR_WIDTH-1:0]              refill_word_offset_addr;
    logic [DCACHE_ADDR_WIDTH-1:0]              refill_addr;
    logic [DCACHE_DATA_WIDTH-1:0]              store_merged_word;

    logic                                      refill_start_event;
    logic                                      refill_beat_event;
    logic                                      refill_word_event;
    logic                                      burst_error_event;
    logic                                      burst_error_q;

    // 0xFF00_0000..0xFFFF_FFFF is uncached. Detect it before starting the
    // synchronous BRAM lookup so bypass transactions do not touch cache RAM.
    assign incoming_uncached =
        (router_addr_i[DCACHE_ADDR_WIDTH-1 -: 8] == 8'hFF);

    assign incoming_tag =
        router_addr_i[
            DCACHE_ADDR_WIDTH-1:
            DCACHE_INDEX_BITS + DCACHE_OFFSET_BITS
        ];

    assign incoming_index =
        router_addr_i[
            DCACHE_INDEX_BITS + DCACHE_OFFSET_BITS - 1:
            DCACHE_OFFSET_BITS
        ];

    assign incoming_word_offset =
        router_addr_i[
            DCACHE_OFFSET_BITS-1:
            DCACHE_BYTE_OFFSET_BITS
        ];

    assign incoming_byte_offset =
        router_addr_i[DCACHE_BYTE_OFFSET_BITS-1:0];

    assign req_is_store = (req_cmd_q == SCR1_MEM_CMD_WR);

    assign lookup_hit =
        cache_lookup_valid_i && (cache_lookup_tag_i == req_tag_q);

    assign refill_last_word = (refill_cnt_q == REFILL_LAST_CNT);

    assign refill_base_addr = {
        req_addr_q[DCACHE_ADDR_WIDTH-1:DCACHE_OFFSET_BITS],
        {DCACHE_OFFSET_BITS{1'b0}}
    };

    assign refill_word_offset_addr =
        {{(DCACHE_ADDR_WIDTH - DCACHE_REFILL_CNT_WIDTH){1'b0}}, refill_cnt_q}
        << DCACHE_BYTE_OFFSET_BITS;

    assign refill_addr = refill_base_addr + refill_word_offset_addr;

    always_comb begin
        req_valid = 1'b0;

        if ((req_cmd_q == SCR1_MEM_CMD_RD)
            || (req_cmd_q == SCR1_MEM_CMD_WR)) begin
            case (req_width_q)
                SCR1_MEM_WIDTH_BYTE: begin
                    req_valid = 1'b1;
                end

                SCR1_MEM_WIDTH_HWORD: begin
                    req_valid = (req_addr_q[0] == 1'b0);
                end

                SCR1_MEM_WIDTH_WORD: begin
                    req_valid = (req_addr_q[1:0] == 2'b00);
                end

                default: begin
                    req_valid = 1'b0;
                end
            endcase
        end
    end

    function automatic logic [DCACHE_DATA_WIDTH-1:0] extract_load_data (
        input logic [DCACHE_DATA_WIDTH-1:0]       word,
        input type_scr1_mem_width_e               width,
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
        input logic [DCACHE_DATA_WIDTH-1:0]       old_word,
        input logic [DCACHE_DATA_WIDTH-1:0]       store_data,
        input type_scr1_mem_width_e               width,
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

    assign store_merged_word = merge_store_data(
        store_old_word_q,
        req_wdata_q,
        req_width_q,
        req_byte_offset_q
    );

    // ------------------------------------------------------------------
    // Controller FSM and all transaction transitions.
    // ------------------------------------------------------------------
    always_comb begin
        state_d = state_q;

        router_req_ack_o = 1'b0;
        router_rdata_o   = response_rdata_q;
        router_resp_o    = SCR1_MEM_RESP_NOTRDY;

        memory_req_o       = 1'b0;
        memory_cmd_o       = SCR1_MEM_CMD_RD;
        memory_width_o     = SCR1_MEM_WIDTH_WORD;
        memory_addr_o      = refill_addr;
        memory_wdata_o     = '0;
        memory_burst_len_o = 8'd0;

        cache_lookup_en_o          = 1'b0;
        cache_lookup_index_o       = incoming_index;
        cache_lookup_word_offset_o = incoming_word_offset;

        cache_line_invalidate_o       = 1'b0;
        cache_line_invalidate_index_o = req_index_q;

        cache_refill_we_o          = 1'b0;
        cache_refill_index_o       = req_index_q;
        cache_refill_word_offset_o = DCACHE_WORD_OFFSET_BITS'(refill_cnt_q);
        cache_refill_data_o        = memory_rdata_i;

        cache_line_commit_o       = 1'b0;
        cache_line_commit_index_o = req_index_q;
        cache_line_commit_tag_o   = req_tag_q;

        cache_store_we_o          = 1'b0;
        cache_store_index_o       = req_index_q;
        cache_store_word_offset_o = req_word_offset_q;
        cache_store_data_o        = store_merged_word;

        perf_req_accept_o   = 1'b0;
        perf_lookup_event_o = 1'b0;
        perf_lookup_hit_o   = lookup_hit;
        perf_req_is_store_o = req_is_store;
        perf_refill_word_o  = 1'b0;
        perf_refill_burst_o = 1'b0;
        perf_burst_error_o  = 1'b0;

        refill_start_event = 1'b0;
        refill_beat_event  = 1'b0;
        refill_word_event  = 1'b0;
        burst_error_event  = 1'b0;

        case (state_q)
            IDLE: begin
                if (router_req_i) begin
                    router_req_ack_o = 1'b1;
                    perf_req_accept_o = 1'b1;

                    // Preserve LOOKUP as the command/width/alignment check
                    // stage, but do not access TAG/DATA BRAM for uncached
                    // 0xFFxx_xxxx transactions.
                    if (!incoming_uncached) begin
                        cache_lookup_en_o = 1'b1;
                    end

                    state_d = LOOKUP;
                end
            end

            LOOKUP: begin
                if (!req_valid) begin
                    state_d = ERROR;
                end else if (req_uncached_q) begin
                    state_d = BYPASS_REQ;
                end else begin
                    perf_lookup_event_o = 1'b1;

                    if (lookup_hit) begin
                        if (req_is_store) begin
                            state_d = STORE_REQ;
                        end else begin
                            router_rdata_o = extract_load_data(
                                cache_lookup_data_i,
                                req_width_q,
                                req_byte_offset_q
                            );
                            router_resp_o = SCR1_MEM_RESP_RDY_OK;
                            state_d = IDLE;
                        end
                    end else begin
                        // No-write-allocate is applied only to cacheable STORE
                        // misses. The resident direct-mapped line is preserved
                        // and the STORE goes straight to the write buffer.
                        if (req_is_store && DCACHE_NO_WRITE_ALLOCATE) begin
                            state_d = STORE_REQ;
                        end else begin
                            // LOAD miss, or legacy write-allocate STORE miss.
                            cache_line_invalidate_o = 1'b1;
                            refill_start_event = 1'b1;
                            state_d = REFILL_REQ;
                        end
                    end
                end
            end

            REFILL_REQ: begin
                memory_req_o   = 1'b1;
                memory_cmd_o   = SCR1_MEM_CMD_RD;
                memory_width_o = SCR1_MEM_WIDTH_WORD;

                if (DCACHE_AXI_BURST_ENABLE) begin
                    memory_addr_o      = refill_base_addr;
                    memory_burst_len_o = 8'(DCACHE_LINE_WORDS - 1);
                end else begin
                    memory_addr_o      = refill_addr;
                    memory_burst_len_o = 8'd0;
                end

                if (memory_req_ack_i) begin
                    if (DCACHE_AXI_BURST_ENABLE) begin
                        perf_refill_burst_o = 1'b1;
                    end
                    state_d = REFILL_WAIT;
                end
            end

            REFILL_WAIT: begin
                memory_cmd_o   = SCR1_MEM_CMD_RD;
                memory_width_o = SCR1_MEM_WIDTH_WORD;

                if (DCACHE_AXI_BURST_ENABLE) begin
                    memory_addr_o      = refill_base_addr;
                    memory_burst_len_o = 8'(DCACHE_LINE_WORDS - 1);

                    if (memory_rvalid_i) begin
                        refill_beat_event = 1'b1;

                        if ((memory_resp_i == SCR1_MEM_RESP_RDY_OK)
                            && !burst_error_q) begin
                            cache_refill_we_o  = 1'b1;
                            perf_refill_word_o = 1'b1;
                            refill_word_event  = 1'b1;
                        end else if (memory_resp_i == SCR1_MEM_RESP_RDY_ER) begin
                            burst_error_event = 1'b1;
                        end

                        if (memory_rlast_i != refill_last_word) begin
                            burst_error_event = 1'b1;
                        end

                        if (memory_rlast_i) begin
                            if (refill_last_word
                                && (memory_resp_i == SCR1_MEM_RESP_RDY_OK)
                                && !burst_error_q) begin
                                cache_line_commit_o = 1'b1;

                                if (req_is_store) begin
                                    state_d = STORE_REQ;
                                end else begin
                                    if (req_word_offset_q
                                        == DCACHE_WORD_OFFSET_BITS'(refill_cnt_q)) begin
                                        router_rdata_o = extract_load_data(
                                            memory_rdata_i,
                                            req_width_q,
                                            req_byte_offset_q
                                        );
                                    end
                                    router_resp_o = SCR1_MEM_RESP_RDY_OK;
                                    state_d = IDLE;
                                end
                            end else begin
                                router_resp_o      = SCR1_MEM_RESP_RDY_ER;
                                perf_burst_error_o = 1'b1;
                                state_d            = IDLE;
                            end
                        end
                    end
                end else begin
                    memory_addr_o      = refill_addr;
                    memory_burst_len_o = 8'd0;

                    if (memory_resp_i == SCR1_MEM_RESP_RDY_OK) begin
                        cache_refill_we_o  = 1'b1;
                        perf_refill_word_o = 1'b1;
                        refill_beat_event  = 1'b1;
                        refill_word_event  = 1'b1;

                        if (refill_last_word) begin
                            cache_line_commit_o = 1'b1;

                            if (req_is_store) begin
                                state_d = STORE_REQ;
                            end else begin
                                if (req_word_offset_q
                                    == DCACHE_WORD_OFFSET_BITS'(refill_cnt_q)) begin
                                    router_rdata_o = extract_load_data(
                                        memory_rdata_i,
                                        req_width_q,
                                        req_byte_offset_q
                                    );
                                end
                                router_resp_o = SCR1_MEM_RESP_RDY_OK;
                                state_d = IDLE;
                            end
                        end else begin
                            state_d = REFILL_REQ;
                        end
                    end else if (memory_resp_i == SCR1_MEM_RESP_RDY_ER) begin
                        state_d = ERROR;
                    end
                end
            end

            STORE_REQ: begin
                // For cacheable stores, memory_req_ack_i is the write-buffer
                // enqueue handshake. The local completion arrives in STORE_WAIT.
                memory_req_o   = 1'b1;
                memory_cmd_o   = SCR1_MEM_CMD_WR;
                memory_width_o = req_width_q;
                memory_addr_o  = req_addr_q;
                memory_wdata_o     = req_wdata_q;
                memory_burst_len_o = 8'd0;

                if (memory_req_ack_i) begin
                    state_d = STORE_WAIT;
                end
            end

            STORE_WAIT: begin
                // The write buffer already captured address/data/width at ACK,
                // so no request payload needs to be driven in this state. This
                // trims STORE_WAIT muxing on the FPGA datapath.
                if (memory_resp_i == SCR1_MEM_RESP_RDY_OK) begin
                    // STORE hit updates the existing L1 line. A no-write-
                    // allocate STORE miss must leave DATA/TAG/VALID untouched.
                    if (store_update_cache_q) begin
                        cache_store_we_o = 1'b1;
                    end
                    router_resp_o = SCR1_MEM_RESP_RDY_OK;
                    state_d = IDLE;
                end else if (memory_resp_i == SCR1_MEM_RESP_RDY_ER) begin
                    state_d = ERROR;
                end
            end

            BYPASS_REQ: begin
                memory_req_o   = 1'b1;
                memory_cmd_o   = req_is_store ? SCR1_MEM_CMD_WR
                                              : SCR1_MEM_CMD_RD;
                memory_width_o = req_width_q;
                memory_addr_o  = req_addr_q;
                memory_wdata_o     = req_is_store ? req_wdata_q : '0;
                memory_burst_len_o = 8'd0;

                if (memory_req_ack_i) begin
                    state_d = BYPASS_WAIT;
                end
            end

            BYPASS_WAIT: begin
                memory_cmd_o   = req_is_store ? SCR1_MEM_CMD_WR
                                              : SCR1_MEM_CMD_RD;
                memory_width_o = req_width_q;
                memory_addr_o  = req_addr_q;
                memory_wdata_o = req_is_store ? req_wdata_q : '0;

                if (memory_resp_i == SCR1_MEM_RESP_RDY_OK) begin
                    if (!req_is_store) begin
                        router_rdata_o = memory_rdata_i;
                    end
                    router_resp_o = SCR1_MEM_RESP_RDY_OK;
                    state_d = IDLE;
                end else if (memory_resp_i == SCR1_MEM_RESP_RDY_ER) begin
                    router_rdata_o = memory_rdata_i;
                    router_resp_o = SCR1_MEM_RESP_RDY_ER;
                    state_d = IDLE;
                end
            end

            ERROR: begin
                router_resp_o = SCR1_MEM_RESP_RDY_ER;
                state_d = IDLE;
            end

            default: begin
                state_d = IDLE;
            end
        endcase
    end

    // ------------------------------------------------------------------
    // Controller registers: state, accepted request, refill progress and
    // response/store context.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q            <= IDLE;
            req_addr_q         <= '0;
            req_tag_q          <= '0;
            req_index_q        <= '0;
            req_word_offset_q  <= '0;
            req_byte_offset_q  <= '0;
            req_cmd_q          <= SCR1_MEM_CMD_RD;
            req_width_q        <= SCR1_MEM_WIDTH_WORD;
            req_wdata_q        <= '0;
            req_uncached_q     <= 1'b0;
            refill_cnt_q       <= '0;
            response_rdata_q      <= '0;
            store_old_word_q      <= '0;
            store_update_cache_q <= 1'b0;
            burst_error_q        <= 1'b0;
        end else begin
            state_q <= state_d;

            if ((state_q == IDLE) && router_req_i) begin
                req_addr_q        <= router_addr_i;
                req_tag_q         <= incoming_tag;
                req_index_q       <= incoming_index;
                req_word_offset_q <= incoming_word_offset;
                req_byte_offset_q <= incoming_byte_offset;
                req_cmd_q         <= router_cmd_i;
                req_width_q       <= router_width_i;
                req_wdata_q       <= router_wdata_i;
                req_uncached_q    <= incoming_uncached;
                // Default for a new transaction; a cacheable STORE sets the
                // precise update policy after the synchronous lookup completes.
                store_update_cache_q <= 1'b0;
            end

            // Compile-time policy selection. With no-write-allocate enabled,
            // only STORE hits modify L1. With it disabled, STORE misses keep
            // the legacy write-allocate behavior and update the refilled line.
            if ((state_q == LOOKUP)
                && req_valid
                && !req_uncached_q
                && req_is_store) begin
                store_update_cache_q <= lookup_hit || !DCACHE_NO_WRITE_ALLOCATE;
            end

            if (refill_start_event) begin
                refill_cnt_q  <= '0;
                burst_error_q <= 1'b0;
            end else begin
                if (refill_beat_event && !refill_last_word) begin
                    refill_cnt_q <= refill_cnt_q + 1'b1;
                end
                if (burst_error_event) begin
                    burst_error_q <= 1'b1;
                end
            end

            // Store hit: preserve the old word while the write-through
            // transaction is sent to backing memory.
            if ((state_q == LOOKUP)
                && req_valid
                && !req_uncached_q
                && req_is_store
                && lookup_hit) begin
                store_old_word_q <= cache_lookup_data_i;
            end

            // Legacy write-allocate mode only: on a STORE miss the old target
            // word arrives as part of refill. This logic is constant-pruned
            // from FPGA builds when DCACHE_NO_WRITE_ALLOCATE is enabled.
            if (!DCACHE_NO_WRITE_ALLOCATE
                && refill_word_event
                && req_is_store
                && (req_word_offset_q
                    == DCACHE_WORD_OFFSET_BITS'(refill_cnt_q))) begin
                store_old_word_q <= memory_rdata_i;
            end

            // Load miss: remember the requested word if it arrives before the
            // final refill word. The final-word case is bypassed combinationally.
            if (refill_word_event
                && !req_is_store
                && (req_word_offset_q
                    == DCACHE_WORD_OFFSET_BITS'(refill_cnt_q))) begin
                response_rdata_q <= extract_load_data(
                    memory_rdata_i,
                    req_width_q,
                    req_byte_offset_q
                );
            end
        end
    end

`ifdef SCR1_TRGT_SIMULATION
    initial begin
        if (DCACHE_AXI_BURST_ENABLE
            && ((DCACHE_LINE_WORDS < 1)
                || (DCACHE_LINE_WORDS > DCACHE_MAX_READ_BURST_BEATS))) begin
            $fatal(1, "dcache_controller: line exceeds maximum AXI read burst");
        end
        if ((DCACHE_MAX_READ_BURST_BEATS < 1)
            || (DCACHE_MAX_READ_BURST_BEATS > 256)) begin
            $fatal(1, "dcache_controller: invalid maximum AXI burst length");
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && DCACHE_AXI_BURST_ENABLE
            && (state_q == REFILL_WAIT) && memory_rvalid_i) begin
            assert (memory_rlast_i == refill_last_word)
                else $error("dcache_controller: AXI RLAST position mismatch");
        end
    end
`endif

endmodule
