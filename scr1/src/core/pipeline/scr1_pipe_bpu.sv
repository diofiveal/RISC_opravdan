/// Copyright (c) 2026. See LICENSE for details.
/// @file       <scr1_pipe_bpu.sv>
/// @brief      Branch Prediction Unit (BPU)
///
/// BHT-based branch predictor for conditional branches and unconditional
/// jumps (JAL, C.J, C.JAL). JALR is NOT predicted (target depends on rs1).
///
/// BHT: 1024 entries x 2-bit saturating counters.
/// Initial state: 2'b01 (Weakly Not-Taken).
///
/// This module is instantiated inside scr1_pipe_ifu.
///

`include "scr1_arch_description.svh"
`include "scr1_riscv_isa_decoding.svh"

module scr1_pipe_bpu (
    // Clock and reset (for BHT training)
    input  logic                                clk,
    input  logic                                rst_n,

    // Predict interface (combinational)
    input  logic [`SCR1_XLEN-1:0]               bpu_pred_pc_i,
    input  logic [`SCR1_IMEM_DWIDTH-1:0]        bpu_pred_instr_i,
    input  logic                                bpu_pred_vld_i,
    input  logic                                bpu_pred_is_hi_i,
    input  logic                                bpu_pred_instr_complete_i,
    output logic                                bpu_pred_taken_o,
    output logic [`SCR1_XLEN-1:0]               bpu_pred_target_o,
    output logic                                bpu_pred_vld_o,

    // Flush interface (fence.i)
    input  logic                                bpu_flush_i,

    // Train interface (sequential)
    input  logic                                bpu_train_vld_i,
    input  logic [`SCR1_XLEN-1:0]               bpu_train_pc_i,
    input  logic                                bpu_train_taken_i
);

//------------------------------------------------------------------------------
// Parameters
//------------------------------------------------------------------------------

localparam int unsigned BHT_ENTRIES   = 1024;
localparam int unsigned BHT_IDX_WIDTH = $clog2(BHT_ENTRIES);

//------------------------------------------------------------------------------
// Functions
//------------------------------------------------------------------------------

// Saturating increment
function automatic logic [1:0] bht_inc (
    input logic [1:0] val
);
    bht_inc = (val == 2'b11) ? 2'b11 : (val + 1'b1);
endfunction : bht_inc

// Saturating decrement
function automatic logic [1:0] bht_dec (
    input logic [1:0] val
);
    bht_dec = (val == 2'b00) ? 2'b00 : (val - 1'b1);
endfunction : bht_dec

//------------------------------------------------------------------------------
// BHT: Branch History Table
//------------------------------------------------------------------------------

logic [1:0] bht [0:BHT_ENTRIES-1];

// BHT index from PC (word-aligned bits)
logic [BHT_IDX_WIDTH-1:0] pred_idx;
logic [BHT_IDX_WIDTH-1:0] train_idx;

assign pred_idx  = bpu_pred_pc_i[BHT_IDX_WIDTH+1:2];
assign train_idx = bpu_train_pc_i[BHT_IDX_WIDTH+1:2];

// Bypass: if training and prediction hit the same BHT entry,
// use the updated value (read-during-write hazard)
logic [BHT_IDX_WIDTH-1:0] pred_idx_eff;
logic [1:0] bht_pred_val;
assign pred_idx_eff = pred_idx;

always_comb begin
    if (bpu_train_vld_i && (train_idx == pred_idx)) begin
        if (bpu_train_taken_i) begin
            bht_pred_val = bht_inc(bht[pred_idx]);
        end else begin
            bht_pred_val = bht_dec(bht[pred_idx]);
        end
    end else begin
        bht_pred_val = bht[pred_idx];
    end
end
logic bht_pred_taken;
assign bht_pred_taken = (bht_pred_val >= 2'b10);

//------------------------------------------------------------------------------
// BHT training and flush (sequential)
//------------------------------------------------------------------------------

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        for (int unsigned i = 0; i < BHT_ENTRIES; i++) begin
            bht[i] = 2'b01;  // blocking (=) required by Verilator BLKLOOPINIT
        end
    end else if (bpu_flush_i) begin
        for (int unsigned i = 0; i < BHT_ENTRIES; i++) begin
            bht[i] = 2'b01;  // blocking (=) required by Verilator BLKLOOPINIT
        end
    end else if (bpu_train_vld_i) begin
        if (bpu_train_taken_i) begin
            bht[train_idx] <= bht_inc(bht[train_idx]);
        end else begin
            bht[train_idx] <= bht_dec(bht[train_idx]);
        end
    end
end

//------------------------------------------------------------------------------
// Instruction half-word selection
//------------------------------------------------------------------------------

logic [15:0] instr_half;
// FIX #2 [BUG-BPU-INSTR-HALF]: After the swap in bpu_pred_instr_i, the instruction
// of interest is always in bits [15:0]. Previously, bpu_pred_is_hi caused
// instr_half to select bits [31:16] which contained the WRONG half-word,
// breaking RVC detection and unaligned branch prediction.
assign instr_half = bpu_pred_instr_i[15:0];

//------------------------------------------------------------------------------
// Instruction type detection
//------------------------------------------------------------------------------

// RVC compressed instructions have bits[1:0] != 2'b11
// Quadrant 0 (00), Quadrant 1 (01), Quadrant 2 (10)
logic is_rvc;
assign is_rvc = (instr_half[1:0] != 2'b11);

// 32-bit branch (B-type): opcode = 1100011 (0x63)
// Only detect when we have the COMPLETE 32-bit word.
logic is_b_type;
assign is_b_type = bpu_pred_instr_complete_i & (instr_half[6:0] == 7'h63);

// JAL: opcode = 1101111 (0x6F)
// Only detect when we have the COMPLETE 32-bit word.
logic is_jal;
assign is_jal = bpu_pred_instr_complete_i & (instr_half[6:0] == 7'h6F);

// RVC conditional branch: C.BEQZ (funct3=110) or C.BNEZ (funct3=111)
// These are in Quadrant 1 (bits[1:0] = 01)
logic is_rvc_branch;
assign is_rvc_branch = (instr_half[1:0] == 2'b01) &
                                       ((instr_half[15:13] == 3'b110) |
                                        (instr_half[15:13] == 3'b111));

// RVC unconditional jump: C.J (funct3=101) or C.JAL (funct3=001)
// These are in Quadrant 2 (bits[1:0] = 10)
logic is_rvc_jump;
assign is_rvc_jump = (instr_half[1:0] == 2'b10) &
                                     ((instr_half[15:13] == 3'b001) |
                                      (instr_half[15:13] == 3'b101));

//------------------------------------------------------------------------------
// bpu_pred_vld_o: 1 for all predictable instructions
//------------------------------------------------------------------------------

assign bpu_pred_vld_o = bpu_pred_vld_i & (
    is_jal
    | is_b_type
    | is_rvc_branch
    | is_rvc_jump
);

//------------------------------------------------------------------------------
// B-type immediate extraction (32-bit conditional branches)
//------------------------------------------------------------------------------
// The instruction is assembled as {lo, hi} in the IMEM word when bpu_pred_is_hi=1.
// For a standard aligned instruction (bpu_pred_is_hi=0):
//   lo half = bits [15:0], hi half = bits [31:16]
//   B-type immediate uses: [31], [7], [30:25], [11:8]
// For a straddling instruction (bpu_pred_is_hi=1):
//   The assembled word is {lo_current, hi_previous} = {current[15:0], previous[31:16]}
//   This is the standard 32-bit layout, so bit positions are the same.

logic [12:0] imm_b;
logic [`SCR1_XLEN-1:0] imm_b_sext;
logic [`SCR1_XLEN-1:0] target_b;

assign imm_b[12]   = bpu_pred_instr_i[31];
assign imm_b[11]   = bpu_pred_instr_i[7];
assign imm_b[10:5] = bpu_pred_instr_i[30:25];
assign imm_b[4:1]  = bpu_pred_instr_i[11:8];
assign imm_b[0]    = 1'b0;

assign imm_b_sext = {{(`SCR1_XLEN-13){imm_b[12]}}, imm_b};
assign target_b   = bpu_pred_pc_i + imm_b_sext;

//------------------------------------------------------------------------------
// J-type immediate extraction (JAL)
//------------------------------------------------------------------------------

logic [20:0] imm_j;
logic [`SCR1_XLEN-1:0] imm_j_sext;
logic [`SCR1_XLEN-1:0] target_j;

assign imm_j[20]    = bpu_pred_instr_i[31];
assign imm_j[10:1]  = bpu_pred_instr_i[30:21];
assign imm_j[11]    = bpu_pred_instr_i[20];
assign imm_j[19:12] = bpu_pred_instr_i[19:12];
assign imm_j[0]     = 1'b0;

assign imm_j_sext = {{(`SCR1_XLEN-21){imm_j[20]}}, imm_j};
assign target_j   = bpu_pred_pc_i + imm_j_sext;

//------------------------------------------------------------------------------
// RVC branch immediate extraction (C.BEQZ / C.BNEZ)
//------------------------------------------------------------------------------

logic [8:0] rvc_br_imm;
logic [`SCR1_XLEN-1:0] rvc_br_imm_sext;
logic [`SCR1_XLEN-1:0] target_rvc_br;

assign rvc_br_imm[8]   = instr_half[12];
assign rvc_br_imm[7:6] = instr_half[6:5];
assign rvc_br_imm[5]   = instr_half[2];
assign rvc_br_imm[4:3] = instr_half[11:10];
assign rvc_br_imm[2:1] = instr_half[4:3];
assign rvc_br_imm[0]   = 1'b0;

assign rvc_br_imm_sext = {{(`SCR1_XLEN-9){rvc_br_imm[8]}}, rvc_br_imm};
assign target_rvc_br   = bpu_pred_pc_i + rvc_br_imm_sext;

//------------------------------------------------------------------------------
// RVC jump immediate extraction (C.J / C.JAL)
//------------------------------------------------------------------------------

logic [11:0] rvc_j_imm;
logic [`SCR1_XLEN-1:0] rvc_j_imm_sext;
logic [`SCR1_XLEN-1:0] target_rvc_j;

assign rvc_j_imm[11]   = instr_half[12];
assign rvc_j_imm[4]    = instr_half[11];
assign rvc_j_imm[9:8]  = instr_half[10:9];
assign rvc_j_imm[10]   = instr_half[8];
assign rvc_j_imm[6]    = instr_half[7];
assign rvc_j_imm[7]    = instr_half[6];
assign rvc_j_imm[3:1]  = instr_half[5:3];
assign rvc_j_imm[5]    = instr_half[2];
assign rvc_j_imm[0]    = 1'b0;

assign rvc_j_imm_sext = {{(`SCR1_XLEN-12){rvc_j_imm[11]}}, rvc_j_imm};
assign target_rvc_j   = bpu_pred_pc_i + rvc_j_imm_sext;

//------------------------------------------------------------------------------
// Prediction output: bpu_pred_taken_o
//------------------------------------------------------------------------------

assign bpu_pred_taken_o = bpu_pred_vld_i & (
    is_jal
    | (is_b_type     & bht_pred_taken)
    | (is_rvc_branch & bht_pred_taken)
    | is_rvc_jump
);

//------------------------------------------------------------------------------
// Target output
//------------------------------------------------------------------------------

always_comb begin
    if (is_jal) begin
        bpu_pred_target_o = target_j;
    end else if (is_rvc_jump) begin
        bpu_pred_target_o = target_rvc_j;
    end else if (is_b_type & bht_pred_taken) begin
        bpu_pred_target_o = target_b;
    end else if (is_rvc_branch & bht_pred_taken) begin
        bpu_pred_target_o = target_rvc_br;
    end else begin
        bpu_pred_target_o = bpu_pred_pc_i + `SCR1_XLEN'd4;
    end
end

`ifdef SCR1_TRGT_SIMULATION
//------------------------------------------------------------------------------
// Assertions
//------------------------------------------------------------------------------
`endif // SCR1_TRGT_SIMULATION

endmodule : scr1_pipe_bpu
