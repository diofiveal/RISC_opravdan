#!/usr/bin/env python3
from pathlib import Path
import shutil
import sys

path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
    "scr1/src/core/pipeline/scr1_pipe_ifu.sv"
)

if not path.exists():
    raise SystemExit(f"File not found: {path}")

text = path.read_text(encoding="utf-8")

old = """`ifdef SCR1_EARLY_BRANCH
logic pc_req_for_instr_hi;
assign pc_req_for_instr_hi = pc_new_req_internal;
`else
logic pc_req_for_instr_hi;
assign pc_req_for_instr_hi = exu2ifu_pc_new_req_i;
`endif
"""

new = """`ifdef SCR1_EARLY_BRANCH
logic pc_req_for_instr_hi;
assign pc_req_for_instr_hi =
       pc_new_req_internal
`ifdef SCR1_BPU_EN
     | bpu_steer
`endif
     ;
`else
logic pc_req_for_instr_hi;
assign pc_req_for_instr_hi = exu2ifu_pc_new_req_i;
`endif
"""

count = text.count(old)
if count != 1:
    raise SystemExit(
        f"Expected exactly one pc_req_for_instr_hi block, found {count}. "
        "No file was modified."
    )

backup = path.with_suffix(path.suffix + ".before_bpu_steer_instr_hi_fix")
shutil.copy2(path, backup)
path.write_text(text.replace(old, new, 1), encoding="utf-8")

print(f"Patched: {path}")
print(f"Backup : {backup}")
print("Fix: bpu_steer now clears instr_hi_rvi_lo_ff in EARLY_BRANCH+BPU mode.")
