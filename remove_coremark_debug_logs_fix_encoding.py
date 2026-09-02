#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path.cwd()
PIPE = ROOT / "scr1/src/core/pipeline"

IDU = PIPE / "scr1_pipe_idu.sv"
EXU = PIPE / "scr1_pipe_exu.sv"
IFU = PIPE / "scr1_pipe_ifu.sv"

def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)

for p in (IDU, EXU, IFU):
    if not p.exists():
        die(f"missing {p}; run from repository root")

def read_sv(path):
    data = path.read_bytes()
    for enc in ("utf-8", "cp1251"):
        try:
            return data.decode(enc), enc
        except UnicodeDecodeError:
            pass
    die(f"cannot decode {path} as UTF-8 or CP1251")

files = {}
encodings = {}
for name, path in (("IDU", IDU), ("EXU", EXU), ("IFU", IFU)):
    files[name], encodings[name] = read_sv(path)
    print(f"[encoding] {name}: {encodings[name]}")

def remove_between(text, start_marker, end_marker, label):
    start = text.find(start_marker)
    if start < 0:
        print(f"[skip] {label}: start marker not present")
        return text, False
    end = text.find(end_marker, start + len(start_marker))
    if end < 0:
        die(f"{label}: found start marker but not end marker")
    print(f"[remove] {label}")
    return text[:start] + text[end:], True

changed = False

# IDU: remove our broad trace block, leaving the following focus marker in place.
files["IDU"], c = remove_between(
    files["IDU"],
    "// DBG_BPU_EARLY_TRACE_IDU",
    "// DBG_BPU_EARLY_FOCUS_IDU",
    "IDU DBG trace"
)
changed |= c

# IDU: remove focus trace up to the normal assertion section.
files["IDU"], c = remove_between(
    files["IDU"],
    "// DBG_BPU_EARLY_FOCUS_IDU",
    "`ifdef SCR1_TRGT_SIMULATION\n//-------------------------------------------------------------------------------\n// Assertion",
    "IDU FOCUS trace"
)
changed |= c

# EXU: same two diagnostic blocks.
files["EXU"], c = remove_between(
    files["EXU"],
    "// DBG_BPU_EARLY_TRACE_EXU",
    "// DBG_BPU_EARLY_FOCUS_EXU",
    "EXU DBG trace"
)
changed |= c

files["EXU"], c = remove_between(
    files["EXU"],
    "// DBG_BPU_EARLY_FOCUS_EXU",
    "`ifdef SCR1_TRGT_SIMULATION\n//------------------------------------------------------------------------------\n// Tracelog signals",
    "EXU FOCUS trace"
)
changed |= c

# New branch-predictor IFU contains a v17 diagnostic block at the very end.
# Remove only the block containing [IFU-DBG], not the functional BPU logic.
ifu_pat = re.compile(
    r"\n`ifdef SCR1_BPU_EN\s*\n"
    r"// v17 DEBUG: Enhanced BPU steer and queue state trace\s*\n"
    r"always_ff\s*@\(posedge clk\)\s*begin[\s\S]*?"
    r"`endif\s*// SCR1_BPU_EN\s*\n"
    r"(?=endmodule\s*:\s*scr1_pipe_ifu)",
    re.M
)
new_ifu, n = ifu_pat.subn("\n", files["IFU"], count=1)
if n:
    print("[remove] IFU [IFU-DBG] trace")
    files["IFU"] = new_ifu
    changed = True
elif "[IFU-DBG]" in files["IFU"]:
    die("IFU still contains [IFU-DBG], but its expected debug block was not recognized")
else:
    print("[skip] IFU [IFU-DBG]: not present")

# Safety: only our verbose displays should disappear. Assertions/$error remain.
for name, text in files.items():
    leftovers = [tag for tag in ("[DBG-", "[FOCUS-", "[IFU-DBG]") if tag in text]
    if leftovers:
        die(f"{name}: debug tags still present: {', '.join(leftovers)}")

if not changed:
    print("No CoreMark debug-log blocks found; nothing changed.")
    sys.exit(0)

# Write only after all checks pass.
IDU.write_text(files["IDU"], encoding=encodings["IDU"])
EXU.write_text(files["EXU"], encoding=encodings["EXU"])
IFU.write_text(files["IFU"], encoding=encodings["IFU"])

print()
print("Done. Removed verbose CoreMark/BPU diagnostic displays.")
print("Functional RTL and assertion $error checks were left intact.")
print()
print("Check:")
print("  git diff --check")
print("  grep -R -nE '\\[DBG-|\\[FOCUS-|\\[IFU-DBG\\]' scr1/src/core/pipeline || true")
