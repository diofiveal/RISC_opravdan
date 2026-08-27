`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module scr1_icache #(
    parameter int unsigned ICACHE_SIZE_BYTES = 4096,
    parameter int unsigned ICACHE_LINE_BYTES = 16,
    parameter int unsigned ICACHE_WAYS = 1
)(
    input  logic                            clk,
    input  logic                            rst_n,

    // IMEM router interface
    output logic                            router_req_ack_o,
    input  logic                            router_req_i,
    input  type_scr1_mem_cmd_e              router_cmd_i,
    input  logic [`SCR1_IMEM_AWIDTH-1:0]    router_addr_i,
    output logic [`SCR1_IMEM_DWIDTH-1:0]    router_rdata_o,
    output type_scr1_mem_resp_e             router_resp_o,

    // AHB/AXI bridge interface

    input  logic                            memory_req_ack_i,
    output logic                            memory_req_o,
    output type_scr1_mem_cmd_e              memory_cmd_o,
    output logic [`SCR1_IMEM_AWIDTH-1:0]    memory_addr_o,
    input  logic [`SCR1_IMEM_DWIDTH-1:0]    memory_rdata_i,
    input  type_scr1_mem_resp_e             memory_resp_i
);

    localparam int unsigned ICACHE_ADDR_WIDTH = `SCR1_IMEM_AWIDTH;
    localparam int unsigned ICACHE_DATA_WIDTH = `SCR1_IMEM_DWIDTH;
    localparam int unsigned ICACHE_WORD_BYTES = ICACHE_DATA_WIDTH / 8;
    localparam int unsigned ICACHE_LINE_WORDS = ICACHE_LINE_BYTES / ICACHE_WORD_BYTES;
    localparam int unsigned ICACHE_LINES = ICACHE_SIZE_BYTES / ICACHE_LINE_BYTES;
    localparam int unsigned ICACHE_OFFSET_BITS = $clog2(ICACHE_LINE_BYTES);
    localparam int unsigned ICACHE_WORD_OFFSET_BITS = $clog2(ICACHE_LINE_WORDS);
    localparam int unsigned ICACHE_INDEX_BITS = $clog2(ICACHE_LINES);
    localparam int unsigned ICACHE_TAG_BITS = ICACHE_ADDR_WIDTH - ICACHE_OFFSET_BITS - ICACHE_INDEX_BITS;
    localparam int unsigned ICACHE_REFILL_CNT_WIDTH = $clog2(ICACHE_LINE_WORDS);
    localparam int unsigned ICACHE_BYTE_OFFSET_BITS = $clog2(ICACHE_WORD_BYTES);
    
    logic req_latch;
    logic lookup_data_latch;
    logic refill_start;
    logic refill_word_we;
    logic refill_cnt_inc;
    logic line_commit;

    logic lookup_hit;
    logic refill_last_word;
    logic [ICACHE_ADDR_WIDTH-1:0] refill_addr;
    logic [ICACHE_DATA_WIDTH-1:0] response_rdata;
`ifdef SCR1_TRGT_SIMULATION
    logic [63:0] perf_accesses;
    logic [63:0] perf_hits;
    logic [63:0] perf_misses;
    logic [63:0] perf_refill_words;
    logic [63:0] perf_stall_cycles;

    logic perf_lookup_event_q;
    logic perf_request_active_q;

    logic perf_router_response;

    assign perf_router_response =
        (router_resp_o == SCR1_MEM_RESP_RDY_OK)
        || (router_resp_o == SCR1_MEM_RESP_RDY_ER);
`endif
    icache_datapath #(
        .ICACHE_ADDR_WIDTH         (ICACHE_ADDR_WIDTH),
        .ICACHE_DATA_WIDTH         (ICACHE_DATA_WIDTH),
        .ICACHE_WORD_BYTES         (ICACHE_WORD_BYTES),
        .ICACHE_LINE_WORDS         (ICACHE_LINE_WORDS),
        .ICACHE_LINES              (ICACHE_LINES),
        .ICACHE_OFFSET_BITS        (ICACHE_OFFSET_BITS),
        .ICACHE_WORD_OFFSET_BITS   (ICACHE_WORD_OFFSET_BITS),
        .ICACHE_INDEX_BITS         (ICACHE_INDEX_BITS),
        .ICACHE_TAG_BITS           (ICACHE_TAG_BITS),
        .ICACHE_REFILL_CNT_WIDTH   (ICACHE_REFILL_CNT_WIDTH),
        .ICACHE_BYTE_OFFSET_BITS   (ICACHE_BYTE_OFFSET_BITS)
    ) i_icache_datapath (
        .clk                  (clk),
        .rst_n                (rst_n),

        .router_addr_i        (router_addr_i),
        .memory_rdata_i       (memory_rdata_i),

        .req_latch_i          (req_latch),
        .lookup_data_latch_i  (lookup_data_latch),
        .refill_start_i       (refill_start),
        .refill_word_we_i     (refill_word_we),
        .refill_cnt_inc_i     (refill_cnt_inc),
        .line_commit_i        (line_commit),

        .lookup_hit_o         (lookup_hit),
        .refill_last_word_o   (refill_last_word),
        .refill_addr_o        (refill_addr),
        .response_rdata_o     (response_rdata)
    );
    icache_fsm i_icache_fsm (
        .clk                  (clk),
        .rst_n                (rst_n),

        .router_req_i         (router_req_i),
        .router_cmd_i         (router_cmd_i),
        .router_req_ack_o     (router_req_ack_o),
        .router_resp_o        (router_resp_o),

        .lookup_hit_i         (lookup_hit),

        .memory_req_ack_i     (memory_req_ack_i),
        .memory_resp_i        (memory_resp_i),
        .memory_req_o         (memory_req_o),

        .refill_last_word_i   (refill_last_word),

        .req_latch_o          (req_latch),
        .lookup_data_latch_o  (lookup_data_latch),
        .refill_start_o       (refill_start),
        .refill_word_we_o     (refill_word_we),
        .refill_cnt_inc_o     (refill_cnt_inc),
        .line_commit_o        (line_commit)
    );

    assign router_rdata_o = response_rdata;
    assign memory_addr_o  = refill_addr;
    assign memory_cmd_o   = SCR1_MEM_CMD_RD;

    `ifdef SCR1_TRGT_SIMULATION
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_accesses         <= 64'd0;
            perf_hits             <= 64'd0;
            perf_misses           <= 64'd0;
            perf_refill_words     <= 64'd0;
            perf_stall_cycles     <= 64'd0;

            perf_lookup_event_q   <= 1'b0;
            perf_request_active_q <= 1'b0;
        end else begin

            if (req_latch) begin
                perf_accesses <= perf_accesses + 64'd1;
            end


            perf_lookup_event_q <= req_latch;

            if (perf_lookup_event_q) begin
                if (lookup_hit) begin
                    perf_hits <= perf_hits + 64'd1;
                end else begin
                    perf_misses <= perf_misses + 64'd1;
                end
            end


            if (refill_word_we) begin
                perf_refill_words <= perf_refill_words + 64'd1;
            end

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