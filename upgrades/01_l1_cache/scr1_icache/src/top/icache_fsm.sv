`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module icache_fsm (
    input  logic                 clk,
    input  logic                 rst_n,

    // Router request
    input  logic                 router_req_i,
    input  type_scr1_mem_cmd_e   router_cmd_i,
    output logic                 router_req_ack_o,
    output type_scr1_mem_resp_e  router_resp_o,

    // Lookup status
    input  logic                 lookup_hit_i,

    // Memory interface status
    input  logic                 memory_req_ack_i,
    input  type_scr1_mem_resp_e  memory_resp_i,
    output logic                 memory_req_o,

    // Refill status
    input  logic                 refill_last_word_i,

    // Datapath controls
    output logic                 req_latch_o, //flag state==IDLE && router_req_i && router_req_ack_o
    output logic                 lookup_data_latch_o, //flag state == LOOKUP && lookup_hit
    output logic                 refill_start_o, // flag start refill state == LOOKUP && !lookup_hit
    output logic                 refill_word_we_o, //flag state == REFILL_WAIT && memory_resp_ok
    output logic                 refill_cnt_inc_o, // flag     (state == REFILL_WAIT) && memory_resp_ok && !refill_last_word_i;
    output logic                 line_commit_o //flag     (state == REFILL_WAIT) && memory_resp_ok && refill_last_word_i;
);
    typedef enum logic[2:0] { 
        IDLE,
        LOOKUP,
        REFILL_REQ,
        REFILL_WAIT,
        RESPOND,
        ERROR
    } state_icache_fsm;

    state_icache_fsm state, next_state;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end
    always_comb begin
        next_state = state;

        router_req_ack_o = 1'b0;
        router_resp_o  = SCR1_MEM_RESP_NOTRDY;

        memory_req_o = 1'b0;

        req_latch_o         = 1'b0;
        lookup_data_latch_o = 1'b0;
        refill_start_o      = 1'b0;
        refill_word_we_o    = 1'b0;
        refill_cnt_inc_o    = 1'b0;
        line_commit_o       = 1'b0;

        case (state)
            IDLE: begin
                if (router_req_i) begin
                    router_req_ack_o = 1'b1;

                    if (router_cmd_i == SCR1_MEM_CMD_RD) begin
                        req_latch_o      = 1'b1;
                        next_state = LOOKUP;
                    end else begin
                        next_state = ERROR;
                    end
                end
            end
            LOOKUP:begin
                if (lookup_hit_i) begin
                    lookup_data_latch_o = 1'b1;
                    next_state = RESPOND;
                end else begin
                    refill_start_o = 1'b1;
                    next_state = REFILL_REQ;
                end
            end
            REFILL_REQ: begin
                memory_req_o = 1'b1;

                if (memory_req_ack_i)begin
                    next_state = REFILL_WAIT;
                end
            end
            REFILL_WAIT: begin
                if (memory_resp_i == SCR1_MEM_RESP_RDY_OK) begin
                    refill_word_we_o = 1'b1;

                    if (refill_last_word_i) begin
                        line_commit_o = 1'b1;
                        next_state = RESPOND;
                    end else begin 
                        refill_cnt_inc_o = 1'b1;
                        next_state = REFILL_REQ;
                    end
                end else if (memory_resp_i == SCR1_MEM_RESP_RDY_ER) begin
                    next_state = ERROR;
                end
            end
            RESPOND: begin
                router_resp_o = SCR1_MEM_RESP_RDY_OK;
                next_state = IDLE;
            end
            ERROR: begin
                router_resp_o = SCR1_MEM_RESP_RDY_ER;
                next_state = IDLE;
            end
            default: begin
                next_state = IDLE;
            end
        endcase
    end
endmodule