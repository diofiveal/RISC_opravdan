`include "scr1_memif.svh"
`include "scr1_arch_description.svh"


module dcache_fsm (
    input  logic                 clk,
    input  logic                 rst_n,

    // Router request
    input  logic                 router_req_i,
    output logic                 router_req_ack_o,
    output type_scr1_mem_resp_e  router_resp_o,

    // Latched request status from datapath
    input  logic                 req_valid_i,
    input  logic                 req_is_store_i,
    input  logic                 lookup_hit_i,

    // Memory interface
    input  logic                 memory_req_ack_i,
    input  type_scr1_mem_resp_e  memory_resp_i,
    output logic                 memory_req_o,
    output logic                 memory_store_o,

    // Refill status
    input  logic                 refill_last_word_i,

    // Datapath controls
    output logic                 req_latch_o,
    output logic                 load_data_latch_o,
    output logic                 refill_start_o,
    output logic                 refill_word_we_o,
    output logic                 refill_cnt_inc_o,
    output logic                 line_commit_o,
    output logic                 store_commit_o
);

    typedef enum logic [2:0] {
        IDLE,
        LOOKUP,
        REFILL_REQ,
        REFILL_WAIT,
        STORE_REQ,
        STORE_WAIT,
        RESPOND,
        ERROR
    } state_dcache_fsm_e;

    state_dcache_fsm_e state;
    state_dcache_fsm_e next_state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end

    always_comb begin
        next_state = state;

        router_req_ack_o = 1'b0;
        router_resp_o    = SCR1_MEM_RESP_NOTRDY;

        memory_req_o   = 1'b0;
        memory_store_o = 1'b0;

        req_latch_o        = 1'b0;
        load_data_latch_o  = 1'b0;
        refill_start_o     = 1'b0;
        refill_word_we_o   = 1'b0;
        refill_cnt_inc_o   = 1'b0;
        line_commit_o      = 1'b0;
        store_commit_o     = 1'b0;

        case (state)
            IDLE: begin
                if (router_req_i) begin
                    router_req_ack_o = 1'b1;
                    req_latch_o      = 1'b1;
                    next_state          = LOOKUP;
                end
            end

            LOOKUP: begin
                if (!req_valid_i) begin
                    next_state = ERROR;
                end else if (req_is_store_i) begin
                    if (lookup_hit_i) begin
                        next_state = STORE_REQ;
                    end else begin
                        refill_start_o = 1'b1;
                        next_state        = REFILL_REQ;
                    end
                end else begin
                    if (lookup_hit_i) begin
                        load_data_latch_o = 1'b1;
                        next_state           = RESPOND;
                    end else begin
                        refill_start_o = 1'b1;
                        next_state        = REFILL_REQ;
                    end
                end
            end

            REFILL_REQ: begin
                memory_req_o   = 1'b1;
                memory_store_o = 1'b0;

                if (memory_req_ack_i) begin
                    next_state = REFILL_WAIT;
                end
            end

            REFILL_WAIT: begin
                if (memory_resp_i == SCR1_MEM_RESP_RDY_OK) begin
                    refill_word_we_o = 1'b1;

                    if (refill_last_word_i) begin
                        line_commit_o = 1'b1;

                        if (req_is_store_i) begin
                            next_state = STORE_REQ;
                        end else begin
                            next_state = RESPOND;
                        end
                    end else begin
                        refill_cnt_inc_o = 1'b1;
                        next_state          = REFILL_REQ;
                    end
                end else if (memory_resp_i == SCR1_MEM_RESP_RDY_ER) begin
                    next_state = ERROR;
                end
            end

            STORE_REQ: begin
                memory_req_o   = 1'b1;
                memory_store_o = 1'b1;

                if (memory_req_ack_i) begin
                    next_state = STORE_WAIT;
                end
            end

            STORE_WAIT: begin
                memory_store_o = 1'b1;

                if (memory_resp_i == SCR1_MEM_RESP_RDY_OK) begin
                    store_commit_o = 1'b1;
                    next_state        = RESPOND;
                end else if (memory_resp_i == SCR1_MEM_RESP_RDY_ER) begin
                    next_state = ERROR;
                end
            end

            RESPOND: begin
                router_resp_o = SCR1_MEM_RESP_RDY_OK;
                next_state       = IDLE;
            end

            ERROR: begin
                router_resp_o = SCR1_MEM_RESP_RDY_ER;
                next_state       = IDLE;
            end

            default: begin
                next_state = IDLE;
            end
        endcase
    end

endmodule