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

if "BPU + EARLY_BRANCH: direct PC-relative jump target" in text:
    print("IDU direct-target patch is already applied.")
    raise SystemExit(0)

marker = """`endif // SCR1_EARLY_BRANCH

end // RV32I(MC) decode
"""

insert = """`endif // SCR1_EARLY_BRANCH

`ifdef SCR1_EARLY_BRANCH
`ifdef SCR1_BPU_EN
    // BPU + EARLY_BRANCH: direct PC-relative jump target.
    // JAL/C.J/C.JAL are predicted in IFU.  They do not use the conditional
    // early-branch comparator, but IFU still needs the correct next PC for
    // ifu_idu_pc_ff when the predicted-taken instruction is accepted.
    // JALR is intentionally excluded because its target depends on rs1.
    if (idu_accept
        && ~ifu2idu_imem_err_i
        && ~idu2exu_cmd_o.exc_req
        && idu2exu_cmd_o.jump_req
        && (idu2exu_cmd_o.sum2_op == SCR1_SUM2_OP_PC_IMM)) begin

        branch_target_early =
            ifu2idu_pc_i + idu2exu_cmd_o.imm;
    end
`endif // SCR1_BPU_EN
`endif // SCR1_EARLY_BRANCH

end // RV32I(MC) decode
"""

count = text.count(marker)
if count != 1:
    raise SystemExit(
        f"Expected one insertion point, found {count}. "
        "No file was modified."
    )

backup = path.with_suffix(path.suffix + ".before_bpu_early_integrated")
shutil.copy2(path, backup)
path.write_text(text.replace(marker, insert, 1), encoding="utf-8")

print(f"Patched: {path}")
print(f"Backup : {backup}")
