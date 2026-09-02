#!/usr/bin/env python3
from pathlib import Path
import shutil

ROOT = Path("scr1/src/core/pipeline")

def add_block(path, marker, tag, block):
    if not path.exists():
        raise SystemExit(f"File not found: {path}")
    text = path.read_text(encoding="utf-8")
    if tag in text:
        print(f"{path.name}: trace already present")
        return
    pos = text.rfind(marker)
    if pos < 0:
        raise SystemExit(f"{path.name}: marker not found: {marker}")
    backup = path.with_suffix(path.suffix + ".before_bpu_early_trace")
    if not backup.exists():
        shutil.copy2(path, backup)
    text = text[:pos] + block + "\n" + text[pos:]
    path.write_text(text, encoding="utf-8")
    print(f"{path.name}: patched (backup: {backup})")

ifu = ROOT / "scr1_pipe_ifu.sv"
idu = ROOT / "scr1_pipe_idu.sv"
exu = ROOT / "scr1_pipe_exu.sv"

ifu_block = r'''
// DBG_BPU_EARLY_TRACE_IFU
`ifdef SCR1_TRGT_SIMULATION
`ifdef SCR1_BPU_EN
`ifdef SCR1_EARLY_BRANCH
integer dbg_bpu_early_ifu_cnt;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        dbg_bpu_early_ifu_cnt <= 0;
    end else if (dbg_bpu_early_ifu_cnt < 200) begin
        if (bpu_steer) begin
            $display("[DBG-IFU-BPU] t=%0t pred_pc=%08h instr=%08h target=%08h is_hi=%0b unal=%0b hi_lo=%0b q_r=%0d q_w=%0d pnd=%0d disc=%0d",
                     $time,
                     ({imem_addr_ff, 2'b00} + {bpu_pred_is_hi, 1'b0}),
                     (bpu_pred_is_hi
                        ? {imem2ifu_rdata_i[15:0], imem2ifu_rdata_i[31:16]}
                        : imem2ifu_rdata_i),
                     bpu_target,
                     bpu_pred_is_hi,
                     new_pc_unaligned_ff,
                     instr_hi_rvi_lo_ff,
                     q_rptr, q_wptr,
                     imem_pnd_txns_cnt,
                     imem_resp_discard_cnt);
            dbg_bpu_early_ifu_cnt <= dbg_bpu_early_ifu_cnt + 1;
        end

        if (pc_new_req_internal) begin
            $display("[DBG-IFU-REDIR] t=%0t src_exu=%0b src_idu=%0b new_pc=%08h idu_pc=%08h pred_v=%0b pred=%0b instr=%08h",
                     $time,
                     exu2ifu_pc_new_req_i,
                     idu2ifu_branch_req_i,
                     pc_new_addr_internal,
                     ifu_idu_pc_ff,
                     ifu2idu_bpu_vld_o,
                     ifu2idu_bpu_pred_o,
                     ifu2idu_instr_o);
            dbg_bpu_early_ifu_cnt <= dbg_bpu_early_ifu_cnt + 1;
        end

        if (ifu_idu_accept && ifu2idu_bpu_vld_o) begin
            $display("[DBG-IFU-IDU] t=%0t pc=%08h instr=%08h pred=%0b idu_corr=%0b idu_target=%08h",
                     $time,
                     ifu_idu_pc_ff,
                     ifu2idu_instr_o,
                     ifu2idu_bpu_pred_o,
                     idu2ifu_branch_req_i,
                     idu2ifu_branch_target_i);
            dbg_bpu_early_ifu_cnt <= dbg_bpu_early_ifu_cnt + 1;
        end

        if (~q_is_empty && q_bpu_kill_head) begin
            $display("[DBG-IFU-KILL] t=%0t q_r=%0d q_w=%0d head=%04h",
                     $time, q_rptr, q_wptr, q_data_head);
            dbg_bpu_early_ifu_cnt <= dbg_bpu_early_ifu_cnt + 1;
        end
    end
end
`endif
`endif
`endif
'''

idu_block = r'''
// DBG_BPU_EARLY_TRACE_IDU
`ifdef SCR1_TRGT_SIMULATION
`ifdef SCR1_BPU_EN
`ifdef SCR1_EARLY_BRANCH
integer dbg_bpu_early_idu_cnt;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        dbg_bpu_early_idu_cnt <= 0;
    end else if (dbg_bpu_early_idu_cnt < 200
                 && idu_accept
                 && (idu2exu_cmd_o.branch_req | idu2exu_cmd_o.jump_req)) begin
        $display("[DBG-IDU] t=%0t pc=%08h instr=%08h br=%0b jump=%0b rvc=%0b pred_v=%0b pred=%0b early_v=%0b early=%0b corr=%0b corr_pc=%08h rs1a=%0d rs2a=%0d rs1=%08h rs2=%08h",
                 $time,
                 ifu2idu_pc_i,
                 ifu2idu_instr_i,
                 idu2exu_cmd_o.branch_req,
                 idu2exu_cmd_o.jump_req,
                 idu2exu_cmd_o.instr_rvc,
                 ifu2idu_bpu_vld_i,
                 ifu2idu_bpu_pred_i,
                 idu2exu_cmd_o.early_branch_valid,
                 idu2exu_cmd_o.early_branch_taken,
                 branch_req_early,
                 branch_target_early,
                 idu2exu_cmd_o.rs1_addr,
                 idu2exu_cmd_o.rs2_addr,
                 mprf2idu_rs1_data_i,
                 mprf2idu_rs2_data_i);
        dbg_bpu_early_idu_cnt <= dbg_bpu_early_idu_cnt + 1;
    end
end
`endif
`endif
`endif
'''

exu_block = r'''
// DBG_BPU_EARLY_TRACE_EXU
`ifdef SCR1_TRGT_SIMULATION
`ifdef SCR1_BPU_EN
`ifdef SCR1_EARLY_BRANCH
integer dbg_bpu_early_exu_cnt;
logic   dbg_bpu_early_exu_resolve;

`ifdef SCR1_MEM_STAGE_EN
assign dbg_bpu_early_exu_resolve =
       exu_queue_vd
     & exu_stage_rdy
     & ~exu_order_block
     & (exu_queue.branch_req | exu_queue.jump_req);
`else
assign dbg_bpu_early_exu_resolve =
       exu_queue_vd
     & exu_rdy
     & (exu_queue.branch_req | exu_queue.jump_req);
`endif

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        dbg_bpu_early_exu_cnt <= 0;
    end else if (dbg_bpu_early_exu_cnt < 200
                 && dbg_bpu_early_exu_resolve) begin
        $display("[DBG-EXU] t=%0t pc=%08h br=%0b jump=%0b pred_v=%0b pred=%0b early_v=%0b early=%0b actual_br=%0b jb=%0b early_miss=%0b br_redir=%0b new_req=%0b new_pc=%08h jb_pc=%08h inc_pc=%08h rs1=%08h rs2=%08h",
                 $time,
                 pc_curr_ff,
                 exu_queue.branch_req,
                 exu_queue.jump_req,
                 exu_bpu_vld_ff,
                 exu_bpu_pred_ff,
                 exu_queue.early_branch_valid,
                 exu_queue.early_branch_taken,
                 branch_taken,
                 jb_taken,
                 early_branch_mispredict,
                 branch_redirect_req,
                 exu2ifu_pc_new_req_o,
                 exu2ifu_pc_new_o,
                 jb_new_pc,
                 inc_pc,
                 mprf2exu_rs1_data_i,
                 mprf2exu_rs2_data_i);
        dbg_bpu_early_exu_cnt <= dbg_bpu_early_exu_cnt + 1;
    end
end
`endif
`endif
`endif
'''

add_block(ifu, "`ifdef SCR1_TRGT_SIMULATION", "DBG_BPU_EARLY_TRACE_IFU", ifu_block)
add_block(idu, "`ifdef SCR1_TRGT_SIMULATION", "DBG_BPU_EARLY_TRACE_IDU", idu_block)
add_block(exu, "`ifdef SCR1_TRGT_SIMULATION", "DBG_BPU_EARLY_TRACE_EXU", exu_block)

print()
print("Trace instrumentation added.")
print("Run CoreMark and grep for DBG- lines.")
