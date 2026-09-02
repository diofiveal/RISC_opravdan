#!/usr/bin/env python3
from pathlib import Path
import shutil
import sys

path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("scr1/src/core/pipeline/scr1_pipe_exu.sv")

if not path.exists():
    raise SystemExit(f"File not found: {path}")

text = path.read_text(encoding="utf-8")
original = text

def replace_once(old: str, new: str, label: str):
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"[{label}] expected exactly 1 match, found {count}. "
            "No file was modified."
        )
    text = text.replace(old, new, 1)

# 1) Local signals
replace_once(
"""`ifdef SCR1_BPU_EN
logic                               exu_bpu_pred_ff;
logic                               exu_bpu_vld_ff;
`endif
""",
"""`ifdef SCR1_BPU_EN
logic                               exu_bpu_pred_ff;
logic                               exu_bpu_vld_ff;
`ifndef SCR1_EARLY_BRANCH
logic                               bpu_mispredict;
logic                               bpu_pred_taken_eff;
`endif // ~SCR1_EARLY_BRANCH
`endif
""",
"local BPU signals"
)

# 2) New-PC mux: add BPU-only recovery before EARLY_BRANCH recovery
replace_once(
"""        wfi_run_start_ff    : exu2ifu_pc_new_o = pc_curr_ff;
        exu_queue.fencei_req: exu2ifu_pc_new_o = inc_pc;
`ifdef SCR1_EARLY_BRANCH
        early_branch_mispredict:
            exu2ifu_pc_new_o = branch_redirect_pc;
`endif // SCR1_EARLY_BRANCH
        default             : exu2ifu_pc_new_o = ialu_addr_res & SCR1_JUMP_MASK;
""",
"""        wfi_run_start_ff    : exu2ifu_pc_new_o = pc_curr_ff;
        exu_queue.fencei_req: exu2ifu_pc_new_o = inc_pc;
`ifdef SCR1_BPU_EN
`ifndef SCR1_EARLY_BRANCH
        // BPU-only mode: recover to the actual target or fall-through.
        bpu_mispredict:
            exu2ifu_pc_new_o = jb_taken ? jb_new_pc : inc_pc;
`endif // ~SCR1_EARLY_BRANCH
`endif // SCR1_BPU_EN
`ifdef SCR1_EARLY_BRANCH
        early_branch_mispredict:
            exu2ifu_pc_new_o = branch_redirect_pc;
`endif // SCR1_EARLY_BRANCH
        default             : exu2ifu_pc_new_o = ialu_addr_res & SCR1_JUMP_MASK;
""",
"new PC mux"
)

# 3) New-PC request: in BPU-only mode, flush correctly predicted taken paths
#    and recover actual mispredictions. Preserve MEM ordering gate.
replace_once(
"""`else
                            | (exu_queue_vd
                               & jb_taken
`ifdef SCR1_MEM_STAGE_EN
                               & ~exu_order_block
`endif
                              );
`endif // SCR1_EARLY_BRANCH
""",
"""`else
`ifdef SCR1_BPU_EN
                            // Correctly predicted taken branch/jump: flush any
                            // younger sequential instruction already queued.
                            | (exu_queue_vd
                               & jb_taken
                               & exu_bpu_vld_ff
`ifdef SCR1_MEM_STAGE_EN
                               & ~exu_order_block
`endif
                              )

                            // Wrong prediction, or JALR which is not predicted.
                            | (bpu_mispredict
`ifdef SCR1_MEM_STAGE_EN
                               & ~exu_order_block
`endif
                              );
`else // ~SCR1_BPU_EN
                            | (exu_queue_vd
                               & jb_taken
`ifdef SCR1_MEM_STAGE_EN
                               & ~exu_order_block
`endif
                              );
`endif // SCR1_BPU_EN
`endif // SCR1_EARLY_BRANCH
""",
"new PC request"
)

# 4) BPU mispredict detection, using latched metadata for the current EXU instruction
replace_once(
"""assign jb_new_pc    = ialu_addr_res & SCR1_JUMP_MASK;

`ifdef SCR1_BPU_EN

`ifdef SCR1_MEM_STAGE_EN
""",
"""assign jb_new_pc    = ialu_addr_res & SCR1_JUMP_MASK;

`ifdef SCR1_BPU_EN
`ifndef SCR1_EARLY_BRANCH

// Use prediction metadata latched together with the instruction in EXU.
assign bpu_pred_taken_eff =
       exu_bpu_vld_ff
     & exu_bpu_pred_ff;

// BPU-only misprediction detection:
// 1. predicted taken, actually not taken;
// 2. JALR is deliberately not predicted by this BPU;
// 3. actually taken, but not predicted taken / no valid prediction.
assign bpu_mispredict =
       exu_queue_vd
     & (
          (bpu_pred_taken_eff
           & ~jb_taken
           & (exu_queue.branch_req | exu_queue.jump_req))

        | (exu_queue.jump_req
           & (exu_queue.sum2_op == SCR1_SUM2_OP_REG_IMM))

        | (jb_taken
           & ~bpu_pred_taken_eff
           & (exu_queue.branch_req | exu_queue.jump_req))
       );

`endif // ~SCR1_EARLY_BRANCH

`ifdef SCR1_MEM_STAGE_EN
""",
"BPU mispredict logic"
)

backup = path.with_suffix(path.suffix + ".bak")
shutil.copy2(path, backup)
path.write_text(text, encoding="utf-8")

print(f"Patched: {path}")
print(f"Backup : {backup}")
print("Mode supported by this step: SCR1_BPU_EN=ON, SCR1_EARLY_BRANCH=OFF")
