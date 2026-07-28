// Not Synthacore. Just me.
// Module for communication between LSU and EXU, if we gonna use SCR1 with MEM stage



`include "scr1_arch_description.svh"
`include "scr1_arch_types.svh"
`include "scr1_memif.svh"
`include "scr1_riscv_isa_decoding.svh"

`ifdef SCR1_MEM_STAGE_EN
module scr1_pipe_mem (
// Common
//------------------------------------------------------------------
input  logic                                                    clk,
input  logic                                                  rst_n,
//------------------------------------------------------------------
// EXU -> MEM
//------------------------------------------------------------------
input  logic                                          exu2mem_req_i,  // Valid signal. EXU already has a memory-interface instruction
input  type_scr1_lsu_cmd_sel_e                    exu2mem_lsu_cmd_i,  // Type of instruction exactly
input  logic [`SCR1_XLEN-1:0]                        exu2mem_addr_i,  // Address calculated by EXU
input  logic [`SCR1_XLEN-1:0]                       exu2mem_sdata_i,  // Data for store
input  logic [`SCR1_MPRF_AWIDTH-1:0]              exu2mem_rd_addr_i,  // Destination register address for LOAD type instructions
input  logic [`SCR1_XLEN-1:0]                          exu2mem_pc_i,  // There is an error check in LSU, so we need a PC for current LSU errors
//------------------------------------------------------------------
// MEM -> EXU
//------------------------------------------------------------------
output  logic                                         mem2exu_rdy_o,  // MEM ready for next instruction from EXU
output  logic                                        mem2exu_done_o,  // Operation in MEM finished
output  logic [`SCR1_XLEN-1:0]                      mem2exu_ldata_o,  // Data for loading in register
output  logic [`SCR1_MPRF_AWIDTH-1:0]             mem2exu_rd_addr_o,  // 
output  logic [`SCR1_XLEN-1:0]                         mem2exu_pc_o,  // For exeptions
output  logic                                         mem2exu_exc_o,  // Exeption flag
output  type_scr1_exc_code_e                     mem2exu_exc_code_o,  // Exeption code
//------------------------------------------------------------------
// MEM <-> DMEM
//------------------------------------------------------------------
output  logic                                        mem2dmem_req_o,
output  type_scr1_mem_cmd_e                          mem2dmem_cmd_o,
output  type_scr1_mem_width_e                      mem2dmem_width_o,
output  logic [`SCR1_DMEM_AWIDTH-1:0]               mem2dmem_addr_o,
output  logic [`SCR1_DMEM_DWIDTH-1:0]              mem2dmem_wdata_o,

input   logic                                    dmem2mem_req_ack_i,
input   logic [`SCR1_DMEM_DWIDTH-1:0]              dmem2mem_rdata_i,
input   type_scr1_mem_resp_e                        dmem2mem_resp_i
//-------------------------------------------------------------------
);
// Pipeline signals
//-------------------------------------------------------------------
logic                                                      mem_vd_ff; 
type_scr1_lsu_cmd_sel_e                               mem_lsu_cmd_ff;
logic [`SCR1_XLEN-1:0]                                   mem_addr_ff;
logic [`SCR1_XLEN-1:0]                                  mem_sdata_ff;
logic [`SCR1_MPRF_AWIDTH-1:0]                         mem_rd_addr_ff;
logic [`SCR1_XLEN-1:0]                                     mem_pc_ff;
//-------------------------------------------------------------------
// Pipeline latch
//-------------------------------------------------------------------
always_ff @(posedge clk, negedge rst_n) begin
  if (~rst_n) begin
    mem_vd_ff <= '0;
  end
  else if (exu2mem_req_i & mem2exu_rdy_o) begin
    mem_vd_ff       <= 1'b1;
    mem_lsu_cmd_ff  <= exu2mem_lsu_cmd_i;
    mem_addr_ff     <= exu2mem_addr_i;
    mem_sdata_ff    <= exu2mem_sdata_i;
    mem_rd_addr_ff  <= exu2mem_rd_addr_i;
    mem_pc_ff       <= exu2mem_pc_i;
  end
end
//--------------------------------------------------------------------- 
endmodule : scr1_pipe_mem
`endif