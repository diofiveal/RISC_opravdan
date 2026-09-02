#!/usr/bin/env python3
from pathlib import Path
import shutil

ROOT = Path("scr1/src/core/pipeline")
ifu = ROOT / "scr1_pipe_ifu.sv"
idu = ROOT / "scr1_pipe_idu.sv"
exu = ROOT / "scr1_pipe_exu.sv"

for p in (ifu, idu, exu):
    if not p.exists():
        raise SystemExit(f"File not found: {p}")

def add_before_last(path: Path, marker: str, tag: str, block: str):
    text = path.read_text(encoding="utf-8")
    if tag in text:
        print(f"{path.name}: already patched")
        return
    pos = text.rfind(marker)
    if pos < 0:
        raise SystemExit(f"{path.name}: marker not found")
    backup = path.with_suffix(path.suffix + ".before_focus_trace")
    if not backup.exists():
        shutil.copy2(path, backup)
    path.write_text(text[:pos] + block + "\n" + text[pos:], encoding="utf-8")
    print(f"{path.name}: patched")

ifu_block = r'''
// DBG_BPU_EARLY_FOCUS_IFU
`ifdef SCR1_TRGT_SIMULATION
`ifdef SCR1_BPU_EN
`ifdef SCR1_EARLY_BRANCH
integer dbg_focus_ifu_cnt;
always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        dbg_focus_ifu_cnt <= 0;
    end else if (dbg_focus_ifu_cnt < 2000) begin
        if (bpu_steer) begin
            $display("[FOCUS-BPU] pc=%08h target=%08h instr=%08h pred_v=%0b pred=%0b is_hi=%0b",
                     ({imem_addr_ff, 2'b00} + {bpu_pred_is_hi, 1'b0}),
                     bpu_target,
                     (bpu_pred_is_hi
                        ? {imem2ifu_rdata_i[15:0], imem2ifu_rdata_i[31:16]}
                        : imem2ifu_rdata_i),
                     bpu_pred_vld,
                     bpu_predict_taken,
                     bpu_pred_is_hi);
            dbg_focus_ifu_cnt <= dbg_focus_ifu_cnt + 1;
        end

        // Only EXU-originated redirects: IDU redirects happen on every iteration
        // of some loops and would flood the trace.
        if (exu2ifu_pc_new_req_i) begin
            $display("[FOCUS-IFU-EXU-REDIR] new_pc=%08h idu_pc=%08h instr=%08h",
                     exu2ifu_pc_new_i, ifu_idu_pc_ff, ifu2idu_instr_o);
            dbg_focus_ifu_cnt <= dbg_focus_ifu_cnt + 1;
        end
    end
end
`endif
`endif
`endif
'''

idu_block = r'''
// DBG_BPU_EARLY_FOCUS_IDU
`ifdef SCR1_TRGT_SIMULATION
`ifdef SCR1_BPU_EN
`ifdef SCR1_EARLY_BRANCH
integer dbg_focus_idu_cnt;
always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        dbg_focus_idu_cnt <= 0;
    end else if (dbg_focus_idu_cnt < 2000
                 && idu_accept
                 && idu2exu_cmd_o.branch_req
                 && (
                      ifu2idu_bpu_vld_i
                      || (mprf2idu_rs1_data_i == mprf2idu_rs2_data_i)
                    )) begin
        $display("[FOCUS-IDU] pc=%08h instr=%08h pred_v=%0b pred=%0b early=%0b corr=%0b corr_pc=%08h rs1=%08h rs2=%08h",
                 ifu2idu_pc_i,
                 ifu2idu_instr_i,
                 ifu2idu_bpu_vld_i,
                 ifu2idu_bpu_pred_i,
                 idu2exu_cmd_o.early_branch_taken,
                 branch_req_early,
                 branch_target_early,
                 mprf2idu_rs1_data_i,
                 mprf2idu_rs2_data_i);
        dbg_focus_idu_cnt <= dbg_focus_idu_cnt + 1;
    end
end
`endif
`endif
`endif
'''

exu_block = r'''
// DBG_BPU_EARLY_FOCUS_EXU
`ifdef SCR1_TRGT_SIMULATION
`ifdef SCR1_BPU_EN
`ifdef SCR1_EARLY_BRANCH
integer dbg_focus_exu_cnt;
always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        dbg_focus_exu_cnt <= 0;
    end else if (dbg_focus_exu_cnt < 2000
                 && exu_queue_vd
                 && (exu_queue.branch_req | exu_queue.jump_req)
                 && (
                      early_branch_mispredict
                      || branch_redirect_req
                      || exu_bpu_vld_ff
                    )) begin
        $display("[FOCUS-EXU] pc=%08h br=%0b jump=%0b pred_v=%0b pred=%0b early_v=%0b early=%0b actual=%0b miss=%0b redir=%0b order_block=%0b new_req=%0b new_pc=%08h jb_pc=%08h inc_pc=%08h rs1=%08h rs2=%08h",
                 pc_curr_ff,
                 exu_queue.branch_req,
                 exu_queue.jump_req,
                 exu_bpu_vld_ff,
                 exu_bpu_pred_ff,
                 exu_queue.early_branch_valid,
                 exu_queue.early_branch_taken,
                 branch_taken,
                 early_branch_mispredict,
                 branch_redirect_req,
`ifdef SCR1_MEM_STAGE_EN
                 exu_order_block,
`else
                 1'b0,
`endif
                 exu2ifu_pc_new_req_o,
                 exu2ifu_pc_new_o,
                 jb_new_pc,
                 inc_pc,
                 mprf2exu_rs1_data_i,
                 mprf2exu_rs2_data_i);
        dbg_focus_exu_cnt <= dbg_focus_exu_cnt + 1;
    end
end
`endif
`endif
`endif
'''

add_before_last(ifu, "`ifdef SCR1_TRGT_SIMULATION", "DBG_BPU_EARLY_FOCUS_IFU", ifu_block)
add_before_last(idu, "`ifdef SCR1_TRGT_SIMULATION", "DBG_BPU_EARLY_FOCUS_IDU", idu_block)
add_before_last(exu, "`ifdef SCR1_TRGT_SIMULATION", "DBG_BPU_EARLY_FOCUS_EXU", exu_block)

print("\nRun CoreMark, then:")
print(r'''grep -E "\[FOCUS-" \
scr1/build/verilator_AXI_MAX_imc_IPIC_1_TCM_1_VIRQ_1_TRACE_0/sim_results.txt \
> bpu_early_focus.txt''')
