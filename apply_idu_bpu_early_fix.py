#!/usr/bin/env python3
from pathlib import Path
import shutil
import sys

path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
    "scr1/src/core/pipeline/scr1_pipe_idu.sv"
)

if not path.exists():
    raise SystemExit(f"File not found: {path}")

text = path.read_text(encoding="utf-8")

old = r'''    idu2exu_cmd_o.early_branch_valid = 1'b1;
    idu2exu_cmd_o.early_branch_taken = branch_taken_early;

    // IFU перенаправляется только для taken
    branch_req_early = branch_taken_early;
end
`endif // SCR1_EARLY_BRANCH
'''

new = r'''    idu2exu_cmd_o.early_branch_valid = 1'b1;
    idu2exu_cmd_o.early_branch_taken = branch_taken_early;

`ifdef SCR1_BPU_EN
    // With BPU enabled, IFU is already following the predicted path.
    // A redirect is needed only when the early IDU result disagrees
    // with that path. No valid prediction means sequential/not-taken.
    branch_req_early =
        branch_taken_early
        != (ifu2idu_bpu_vld_i & ifu2idu_bpu_pred_i);

    // Recovery address depends on the real early branch result:
    //   actual taken     -> branch target
    //   actual not-taken -> fall-through PC (+2 for RVC, +4 for RVI)
    if (~branch_taken_early) begin
        branch_target_early =
            ifu2idu_pc_i
            + (idu2exu_cmd_o.instr_rvc
               ? `SCR1_XLEN'd2
               : `SCR1_XLEN'd4);
    end
`else
    // Original EARLY_BRANCH behavior without predictor.
    branch_req_early = branch_taken_early;
`endif // SCR1_BPU_EN
end
`endif // SCR1_EARLY_BRANCH
'''

count = text.count(old)
if count != 1:
    raise SystemExit(
        "Expected exactly one EARLY_BRANCH decision block, "
        f"found {count}. No file was modified."
    )

patched = text.replace(old, new, 1)

backup = path.with_suffix(path.suffix + ".bak")
shutil.copy2(path, backup)
path.write_text(patched, encoding="utf-8")

print(f"Patched: {path}")
print(f"Backup : {backup}")
print()
print("Combined IDU behavior:")
print("  prediction == early actual -> no IDU redirect")
print("  predicted NT, actual T     -> redirect to branch target")
print("  predicted T, actual NT     -> redirect to fall-through")
print("  no valid prediction        -> behaves as predicted NT")
print()
print("NOTE: do not test BPU+EARLY_BRANCH yet until IFU arbitration is patched too.")
