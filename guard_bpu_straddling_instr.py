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

old = """assign bpu_can_steer =
       imem_resp_vd
     & bpu_pred_instr_complete
`ifdef SCR1_DBG_EN
     & ~hdu2ifu_pbuf_fetch_i
`endif
     ;
"""

new = """assign bpu_can_steer =
       imem_resp_vd
     & bpu_pred_instr_complete

`ifdef SCR1_EARLY_BRANCH
     // Temporary correctness guard for the combined BPU + EARLY_BRANCH mode.
     // A 32-bit instruction completed across two IMEM words does not yet carry
     // its BPU metadata reliably with the instruction through the IFU queue.
     // Let EARLY_BRANCH/EXU handle that case instead of steering speculatively.
     & ~instr_hi_rvi_lo_ff
`endif

`ifdef SCR1_DBG_EN
     & ~hdu2ifu_pbuf_fetch_i
`endif
     ;
"""

count = text.count(old)
if count != 1:
    raise SystemExit(
        f"Expected exactly one bpu_can_steer block, found {count}. "
        "No file was modified."
    )

backup = path.with_suffix(path.suffix + ".before_straddle_guard")
shutil.copy2(path, backup)
path.write_text(text.replace(old, new, 1), encoding="utf-8")

print(f"Patched: {path}")
print(f"Backup : {backup}")
print("Combined mode now disables BPU steering only for cross-word 32-bit instructions.")
