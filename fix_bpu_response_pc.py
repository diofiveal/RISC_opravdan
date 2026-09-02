#!/usr/bin/env python3
from pathlib import Path
import shutil
import re
import sys

path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
    "scr1/src/core/pipeline/scr1_pipe_ifu.sv"
)

if not path.exists():
    raise SystemExit(f"File not found: {path}")

text = path.read_text(encoding="utf-8")

if "bpu_resp_word_pc" in text:
    print("BPU response-PC fix already appears to be present.")
    raise SystemExit(0)

# 1) Add signal declaration near existing BPU control signals.
decl_pat = re.compile(
    r"(logic\s+bpu_pred_instr_complete\s*;\s*\n"
    r"logic\s+bpu_can_steer\s*;)",
    re.M,
)
m = decl_pat.search(text)
if not m:
    raise SystemExit(
        "Could not find BPU signal declarations near bpu_can_steer. "
        "No file was modified."
    )

decl_new = m.group(1) + r'''

// PC of the 32-bit IMEM word whose response is being decoded now.
// imem_addr_ff may already point to a newer accepted request.
logic [`SCR1_XLEN-1:0]              bpu_resp_word_pc;
'''
text = text[:m.start()] + decl_new + text[m.end():]

# 2) Compute response PC before the BPU instance.
instance_marker = "scr1_pipe_bpu i_pipe_bpu"
pos = text.find(instance_marker)
if pos < 0:
    raise SystemExit("Could not find scr1_pipe_bpu instance. No file was modified.")

assign_block = r'''
// imem_addr_ff advances on request acknowledgement. If one or more valid
// requests are outstanding, the response returning now belongs to an older
// address. Each outstanding IMEM word advances the address by 4 bytes.
assign bpu_resp_word_pc =
       {imem_addr_ff, 2'b00}
     - ({{(`SCR1_XLEN-SCR1_TXN_CNT_W){1'b0}},
         imem_vd_pnd_txns_cnt} << 2);

'''
text = text[:pos] + assign_block + text[pos:]

# 3) Replace only the PC passed to BPU.
port_pat = re.compile(
    r"\.bpu_pred_pc_i\s*\(\s*"
    r"\{imem_addr_ff,\s*2'b00\}\s*"
    r"\+\s*\{bpu_pred_is_hi,\s*1'b0\}\s*"
    r"\)",
    re.S,
)
m = port_pat.search(text)
if not m:
    raise SystemExit(
        "Could not find the old bpu_pred_pc_i expression. "
        "No file was modified."
    )

port_new = r'''.bpu_pred_pc_i               (
        bpu_resp_word_pc
        + {{(`SCR1_XLEN-2){1'b0}}, bpu_pred_is_hi, 1'b0}
    )'''
text = text[:m.start()] + port_new + text[m.end():]

backup = path.with_suffix(path.suffix + ".before_bpu_response_pc_fix")
shutil.copy2(path, backup)
path.write_text(text, encoding="utf-8")

print(f"Patched: {path}")
print(f"Backup : {backup}")
print()
print("BPU now computes targets from the PC of the IMEM response,")
print("not from imem_addr_ff's newer request address.")
