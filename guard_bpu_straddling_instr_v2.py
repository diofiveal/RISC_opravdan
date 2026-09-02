#!/usr/bin/env python3
from pathlib import Path
import shutil
import sys
import re

path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
    "scr1/src/core/pipeline/scr1_pipe_ifu.sv"
)

if not path.exists():
    raise SystemExit(f"File not found: {path}")

text = path.read_text(encoding="utf-8")

# If already patched, do nothing.
if "~instr_hi_rvi_lo_ff" in text and "assign bpu_can_steer" in text:
    print("The straddling-instruction guard appears to be already present.")
    raise SystemExit(0)

# Find the whole continuous assignment regardless of indentation/extra lines.
m = re.search(
    r"assign\s+bpu_can_steer\s*=\s*(.*?);",
    text,
    flags=re.S
)

if not m:
    raise SystemExit(
        "Could not find 'assign bpu_can_steer = ... ;' in "
        f"{path}. No file was modified."
    )

old_block = m.group(0)

# Prefer to insert before the debug qualifier if present; otherwise before ';'.
if "`ifdef SCR1_DBG_EN" in old_block:
    new_block = old_block.replace(
        "`ifdef SCR1_DBG_EN",
        """`ifdef SCR1_EARLY_BRANCH
     // In combined BPU + EARLY_BRANCH mode, temporarily disable speculative
     // steering for a 32-bit instruction completed across two IMEM words.
     & ~instr_hi_rvi_lo_ff
`endif

`ifdef SCR1_DBG_EN""",
        1
    )
else:
    semi = old_block.rfind(";")
    body = old_block[:semi].rstrip()
    new_block = body + """
`ifdef SCR1_EARLY_BRANCH
     // Temporary correctness guard for cross-word 32-bit instructions.
     & ~instr_hi_rvi_lo_ff
`endif
     ;"""

backup = path.with_suffix(path.suffix + ".before_straddle_guard_v2")
shutil.copy2(path, backup)

patched = text[:m.start()] + new_block + text[m.end():]
path.write_text(patched, encoding="utf-8")

print(f"Patched: {path}")
print(f"Backup : {backup}")
print()
print("New bpu_can_steer block:")
print("--------------------------------")
print(new_block)
print("--------------------------------")
