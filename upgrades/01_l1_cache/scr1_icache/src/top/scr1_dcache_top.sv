`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module scr1_dcache #(
    parameter int unsigned DCACHE_SIZE_BYTES = 4096,
    parameter int unsigned DCACHE_LINE_BYTES = 16,
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
    localparam int unsigned DCACHE_LINE_WORDS = DCACHE_LINE_BYTES / DCACHE_WORD_BYTES;
    localparam int unsigned DCACHE_LINES = DCACHE_SIZE_BYTES / DCACHE_LINE_BYTES;
    localparam int unsigned DCACHE_OFFSET_BITS = $clog2(DCACHE_LINE_BYTES);
    localparam int unsigned DCACHE_WORD_OFFSET_BITS = (DCACHE_LINE_WORDS > 1) ? $clog2(DCACHE_LINE_WORDS) : 1;
    localparam int unsigned DCACHE_INDEX_BITS = (DCACHE_LINES > 1) ? $clog2(DCACHE_LINES) : 1;
    localparam int unsigned DCACHE_TAG_BITS = DCACHE_ADDR_WIDTH - DCACHE_OFFSET_BITS - DCACHE_INDEX_BITS;
    localparam int unsigned DCACHE_REFILL_CNT_WIDTH = (DCACHE_LINE_WORDS > 1) ? $clog2(DCACHE_LINE_WORDS) : 1;
    localparam int unsigned DCACHE_BYTE_OFFSET_BITS = (DCACHE_WORD_BYTES > 1) ? $clog2(DCACHE_WORD_BYTES) : 1;

    // FSM to datapath controls
    logic req_latch;
    logic load_data_latch;
    logic refill_start;
    logic refill_word_we;
    logic refill_cnt_inc;
    logic line_commit;
    logic store_commit;

    // Datapath to FSM status
    logic req_valid;
    logic req_is_store;
    logic lookup_hit;
    logic refill_last_word;

    // Memory transaction selection
    logic memory_store;

    // Datapath outputs
    logic [DCACHE_ADDR_WIDTH-1:0] refill_addr;
    logic [DCACHE_ADDR_WIDTH-1:0] store_addr;
    type_scr1_mem_width_e         store_width;
    logic [DCACHE_DATA_WIDTH-1:0] store_wdata;
    logic [DCACHE_DATA_WIDTH-1:0] response_rdata;
`ifdef SCR1_TRGT_SIMULATION
    // ---------------------------------------------------------------------
    // D-cache performance counters
    //
    // Counters are intentionally internal to the cache. The simulation
    // testbench reads them through the instance hierarchy.
    // ---------------------------------------------------------------------
    logic [63:0] perf_load_accesses;
    logic [63:0] perf_store_accesses;
    logic [63:0] perf_hits;
    logic [63:0] perf_misses;
    logic [63:0] perf_load_misses;
    logic [63:0] perf_store_misses;
    logic [63:0] perf_refill_words;
    logic [63:0] perf_stall_cycles;

    // req_latch is asserted when a router request is accepted in IDLE.
    // The actual tag lookup result becomes usable on the following cycle.
    logic perf_lookup_event_q;

    // Marks a request that has been accepted but has not received its
    // final RDY_OK/RDY_ER response yet.
    logic perf_request_active_q;

    logic perf_router_response;
    assign perf_router_response =
        (router_resp_o == SCR1_MEM_RESP_RDY_OK)
        || (router_resp_o == SCR1_MEM_RESP_RDY_ER);
`endif
    dcache_datapath #(
        .DCACHE_ADDR_WIDTH        (DCACHE_ADDR_WIDTH),
        .DCACHE_DATA_WIDTH        (DCACHE_DATA_WIDTH),
        .DCACHE_WORD_BYTES        (DCACHE_WORD_BYTES),
        .DCACHE_LINE_WORDS        (DCACHE_LINE_WORDS),
        .DCACHE_LINES             (DCACHE_LINES),
        .DCACHE_OFFSET_BITS       (DCACHE_OFFSET_BITS),
        .DCACHE_WORD_OFFSET_BITS  (DCACHE_WORD_OFFSET_BITS),
        .DCACHE_INDEX_BITS        (DCACHE_INDEX_BITS),
        .DCACHE_TAG_BITS          (DCACHE_TAG_BITS),
        .DCACHE_REFILL_CNT_WIDTH  (DCACHE_REFILL_CNT_WIDTH),
        .DCACHE_BYTE_OFFSET_BITS  (DCACHE_BYTE_OFFSET_BITS)
    ) i_dcache_datapath (
        .clk                     (clk),
        .rst_n                   (rst_n),

        .router_cmd_i            (router_cmd_i),
        .router_width_i          (router_width_i),
        .router_addr_i           (router_addr_i),
        .router_wdata_i          (router_wdata_i),
        .memory_rdata_i          (memory_rdata_i),

        .req_latch_i             (req_latch),
        .load_data_latch_i       (load_data_latch),
        .refill_start_i          (refill_start),
        .refill_word_we_i        (refill_word_we),
        .refill_cnt_inc_i        (refill_cnt_inc),
        .line_commit_i           (line_commit),
        .store_commit_i          (store_commit),

        .req_valid_o             (req_valid),
        .req_is_store_o          (req_is_store),
        .lookup_hit_o            (lookup_hit),
        .refill_last_word_o      (refill_last_word),

        .refill_addr_o           (refill_addr),
        .store_addr_o            (store_addr),
        .store_width_o           (store_width),
        .store_wdata_o           (store_wdata),
        .response_rdata_o        (response_rdata)
    );

    dcache_fsm i_dcache_fsm (
        .clk                     (clk),
        .rst_n                   (rst_n),

        .router_req_i            (router_req_i),
        .router_req_ack_o        (router_req_ack_o),
        .router_resp_o           (router_resp_o),

        .req_valid_i             (req_valid),
        .req_is_store_i          (req_is_store),
        .lookup_hit_i            (lookup_hit),

        .memory_req_ack_i        (memory_req_ack_i),
        .memory_resp_i           (memory_resp_i),
        .memory_req_o            (memory_req_o),
        .memory_store_o          (memory_store),

        .refill_last_word_i      (refill_last_word),

        .req_latch_o             (req_latch),
        .load_data_latch_o       (load_data_latch),
        .refill_start_o          (refill_start),
        .refill_word_we_o        (refill_word_we),
        .refill_cnt_inc_o        (refill_cnt_inc),
        .line_commit_o           (line_commit),
        .store_commit_o          (store_commit)
    );
    assign router_rdata_o = response_rdata;
    assign memory_cmd_o = memory_store ? SCR1_MEM_CMD_WR : SCR1_MEM_CMD_RD;
    assign memory_width_o = memory_store ? store_width : SCR1_MEM_WIDTH_WORD;
    assign memory_addr_o = memory_store ? store_addr : refill_addr;
    assign memory_wdata_o = memory_store ? store_wdata : '0;

`ifdef SCR1_TRGT_SIMULATION
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

            perf_lookup_event_q   <= 1'b0;
            perf_request_active_q <= 1'b0;
        end else begin
            // -------------------------------------------------------------
            // Accepted D-cache accesses
            //
            // req_latch is generated together with router_req_ack_o, so each
            // accepted router request is counted exactly once.
            // -------------------------------------------------------------
            if (req_latch) begin
                if (router_cmd_i == SCR1_MEM_CMD_RD) begin
                    perf_load_accesses <= perf_load_accesses + 64'd1;
                end else if (router_cmd_i == SCR1_MEM_CMD_WR) begin
                    perf_store_accesses <= perf_store_accesses + 64'd1;
                end
            end

            // req_latch accepts the request during IDLE. On the next cycle
            // the FSM is in LOOKUP and lookup_hit/req_is_store describe the
            // saved request.
            perf_lookup_event_q <= req_latch;

            if (perf_lookup_event_q && req_valid) begin
                if (lookup_hit) begin
                    perf_hits <= perf_hits + 64'd1;
                end else begin
                    perf_misses <= perf_misses + 64'd1;

                    if (req_is_store) begin
                        perf_store_misses <= perf_store_misses + 64'd1;
                    end else begin
                        perf_load_misses <= perf_load_misses + 64'd1;
                    end
                end
            end

            // One completed memory read response writes one word into the
            // cache-line refill buffer/array.
            if (refill_word_we) begin
                perf_refill_words <= perf_refill_words + 64'd1;
            end

            // -------------------------------------------------------------
            // D-cache stall cycles
            //
            // Definition used here:
            // every full cycle after a router request has been accepted and
            // before the cache returns RDY_OK or RDY_ER.
            //
            // The acceptance cycle itself is not counted. LOOKUP, refill,
            // store wait and response-wait cycles are counted.
            // -------------------------------------------------------------
            if (perf_request_active_q) begin
                perf_stall_cycles <= perf_stall_cycles + 64'd1;
            end

            if (req_latch) begin
                perf_request_active_q <= 1'b1;
            end

            if (perf_router_response) begin
                perf_request_active_q <= 1'b0;
            end
        end
    end
`endif
`ifdef SCR1_TRGT_SIMULATION
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