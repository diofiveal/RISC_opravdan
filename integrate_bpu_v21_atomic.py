#!/usr/bin/env python3
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path.cwd()
PIPE = ROOT / "scr1/src/core/pipeline"

IDU = PIPE / "scr1_pipe_idu.sv"
EXU = PIPE / "scr1_pipe_exu.sv"
IFU = PIPE / "scr1_pipe_ifu.sv"
BPU = PIPE / "scr1_pipe_bpu.sv"
TOP = PIPE / "scr1_pipe_top.sv"
TARGETS = [IDU, EXU, IFU, BPU, TOP]


def die(msg):
    print(f"\nERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def run(*args, check=True):
    p = subprocess.run(
        args,
        cwd=ROOT,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True
    )
    if check and p.returncode:
        if p.stdout:
            print(p.stdout, end="")
        if p.stderr:
            print(p.stderr, end="", file=sys.stderr)
        die("command failed: " + " ".join(args))
    return p.stdout


def rel(path):
    return path.relative_to(ROOT).as_posix()


def git_show(ref, path):
    return run("git", "show", f"{ref}:{rel(path)}")


def rx1(text, pattern, repl, label, flags=re.M):
    new, n = re.subn(pattern, repl, text, count=1, flags=flags)
    if n != 1:
        die(f"{label}: expected regex anchor exactly once, found {n}")
    return new


def must_contain(text, token, label):
    if token not in text:
        die(f"{label}: missing expected token {token!r}")


if not PIPE.is_dir():
    die("run this script from the RISC_opravdan repository root")

branch = run("git", "branch", "--show-current").strip()
if branch != "integration-early-bpu-l1":
    die(f"expected branch integration-early-bpu-l1, current branch is {branch!r}")

# Previous failed script may have already replaced IFU/BPU. Allow those two
# to be dirty, but do not silently overwrite hand edits in IDU/EXU/TOP.
dirty_lines = run("git", "status", "--porcelain", "--", *(str(p) for p in TARGETS)).splitlines()
unsafe_dirty = []
for line in dirty_lines:
    name = line[3:].replace("\\", "/")
    if name not in {rel(IFU), rel(BPU)}:
        unsafe_dirty.append(line)
if unsafe_dirty:
    die(
        "IDU/EXU/pipe_top have uncommitted changes. Commit/stash them first.\n"
        "Only IFU/BPU may be dirty after the previous failed integration.\n"
        + "\n".join(unsafe_dirty)
    )

print("[1/7] Fetching myrepo/branch-predictor...")
run("git", "fetch", "myrepo", "branch-predictor")
remote_hash = run("git", "rev-parse", "myrepo/branch-predictor").strip()
print(f"      predictor commit: {remote_hash[:12]}")

# Build everything in memory first. Current pipeline work comes from HEAD;
# only IFU/BPU come from the predictor branch.
idu = git_show("HEAD", IDU)
exu = git_show("HEAD", EXU)
top = git_show("HEAD", TOP)
ifu = git_show("myrepo/branch-predictor", IFU)
bpu = git_show("myrepo/branch-predictor", BPU)

must_contain(bpu, "module scr1_pipe_bpu", "BPU")
must_contain(ifu, "ifu2idu_bpu_target_o", "new IFU")
must_contain(ifu, "ifu2idu_bpu_steer_bypass_o", "new IFU")

# ----------------------------------------------------------------------
# IFU
# ----------------------------------------------------------------------
print("[2/7] Preparing latest IFU + EARLY_BRANCH PC sideband...")

ifu = rx1(
    ifu,
    r"(output\s+logic\s+ifu2idu_vd_o\s*// IFU request\s*\n)(`ifdef SCR1_BPU_EN)",
    """\\1`ifdef SCR1_EARLY_BRANCH
    ,output logic [`SCR1_XLEN-1:0]                  ifu2idu_pc_o                // PC paired with IFU->IDU instruction
`endif // SCR1_EARLY_BRANCH
\\2""",
    "IFU EARLY_BRANCH PC port"
)

ifu = rx1(
    ifu,
    r"(// Local signals declaration\s*\n//-+\s*\n)",
    """\\1
`ifdef SCR1_EARLY_BRANCH
logic                               ifu_idu_accept;
logic                               ifu_idu_pc_advance;
logic [`SCR1_XLEN-1:0]              ifu_idu_pc_ff;
logic [`SCR1_XLEN-1:0]              ifu_idu_instr_size;
`ifdef SCR1_BPU_EN
logic                               ifu_idu_bpu_path_taken;
`endif // SCR1_BPU_EN
`endif // SCR1_EARLY_BRANCH

""",
    "IFU PC tracker declarations"
)

ifu_tracker = """
`ifdef SCR1_EARLY_BRANCH
// PC paired with the instruction accepted by IDU.  A BPU prediction is not
// treated as taken unless the new IFU metadata says fetch really steered.
assign ifu_idu_accept = ifu2idu_vd_o & idu2ifu_rdy_i;
assign ifu_idu_pc_advance = ifu_idu_accept
`ifdef SCR1_DBG_EN
                          & ~hdu2ifu_pbuf_fetch_i
`endif // SCR1_DBG_EN
                          ;

`ifdef SCR1_RVC_EXT
assign ifu_idu_instr_size = (ifu2idu_instr_o[1:0] == 2'b11)
                          ? `SCR1_XLEN'd4
                          : `SCR1_XLEN'd2;
`else
assign ifu_idu_instr_size = `SCR1_XLEN'd4;
`endif // SCR1_RVC_EXT

`ifdef SCR1_BPU_EN
assign ifu_idu_bpu_path_taken =
       ifu2idu_bpu_vld_o
     & ifu2idu_bpu_pred_o
     & (ifu2idu_bpu_str_o | ifu2idu_bpu_steer_bypass_o);
`endif // SCR1_BPU_EN

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        ifu_idu_pc_ff <= SCR1_RST_VECTOR;
    end else if (exu2ifu_pc_new_req_i) begin
        // pipe_top also routes IDU EARLY_BRANCH correction through this input.
        ifu_idu_pc_ff <= exu2ifu_pc_new_i;
    end else if (ifu_idu_pc_advance) begin
`ifdef SCR1_BPU_EN
        if (ifu_idu_bpu_path_taken)
            ifu_idu_pc_ff <= ifu2idu_bpu_target_o;
        else
`endif // SCR1_BPU_EN
            ifu_idu_pc_ff <= ifu_idu_pc_ff + ifu_idu_instr_size;
    end
end

assign ifu2idu_pc_o = ifu_idu_pc_ff;
`endif // SCR1_EARLY_BRANCH

"""

ifu = rx1(
    ifu,
    r"(`endif\s+// SCR1_NO_DEC_STAGE\s*\n\s*)(`ifdef SCR1_DBG_EN\s*\nassign ifu2hdu_pbuf_rdy_o)",
    r"\1" + ifu_tracker + r"\2",
    "IFU common PC tracker insertion"
)

# ----------------------------------------------------------------------
# IDU
# ----------------------------------------------------------------------
print("[3/7] Preparing current IDU...")

idu = rx1(
    idu,
    r"`ifdef SCR1_BPU_EN\s*\n"
    r"\s*input\s+logic\s+ifu2idu_bpu_pred_i,\s*\n"
    r"\s*input\s+logic\s+ifu2idu_bpu_vld_i,\s*\n"
    r"\s*output\s+logic\s+idu2exu_bpu_pred_o,\s*\n"
    r"\s*output\s+logic\s+idu2exu_bpu_vld_o,\s*\n"
    r"`endif",
    """`ifdef SCR1_BPU_EN
    input   logic                          ifu2idu_bpu_pred_i,
    input   logic                          ifu2idu_bpu_vld_i,
    input   logic [`SCR1_XLEN-1:0]         ifu2idu_bpu_target_i,
    input   logic                          ifu2idu_bpu_str_i,
    input   logic                          ifu2idu_bpu_steer_bypass_i,
    output  logic                          idu2exu_bpu_pred_o,
    output  logic                          idu2exu_bpu_vld_o,
    output  logic [`SCR1_XLEN-1:0]         idu2exu_bpu_target_o,
    output  logic                          idu2exu_bpu_str_o,
    output  logic                          idu2exu_bpu_steer_bypass_o,
`endif""",
    "IDU BPU ports"
)

idu = rx1(
    idu,
    r"(logic\s+idu_accept;\s*// for handshake\s*\n)",
    """\\1`ifdef SCR1_BPU_EN
logic                               bpu_path_taken_early;
`endif // SCR1_BPU_EN
""",
    "IDU BPU path signal"
)

idu = rx1(
    idu,
    r"`ifdef SCR1_BPU_EN\s*\n\s*"
    r"assign\s+idu2exu_bpu_pred_o\s*=\s*ifu2idu_bpu_pred_i;\s*\n"
    r"assign\s+idu2exu_bpu_vld_o\s*=\s*ifu2idu_bpu_vld_i;\s*\n\s*"
    r"`endif\s*// SCR1_BPU_EN",
    """`ifdef SCR1_BPU_EN

assign idu2exu_bpu_pred_o          = ifu2idu_bpu_pred_i;
assign idu2exu_bpu_vld_o           = ifu2idu_bpu_vld_i;
assign idu2exu_bpu_target_o        = ifu2idu_bpu_target_i;
assign idu2exu_bpu_str_o           = ifu2idu_bpu_str_i;
assign idu2exu_bpu_steer_bypass_o  = ifu2idu_bpu_steer_bypass_i;

`ifdef SCR1_EARLY_BRANCH
assign bpu_path_taken_early =
       ifu2idu_bpu_vld_i
     & ifu2idu_bpu_pred_i
     & (ifu2idu_bpu_str_i | ifu2idu_bpu_steer_bypass_i);
`endif // SCR1_EARLY_BRANCH

`endif // SCR1_BPU_EN""",
    "IDU BPU pass-through"
)

idu = rx1(
    idu,
    r"branch_req_early\s*=\s*\n"
    r"\s*branch_taken_early\s*\n"
    r"\s*!=\s*\(ifu2idu_bpu_vld_i\s*&\s*ifu2idu_bpu_pred_i\);",
    """branch_req_early =
           (branch_taken_early != bpu_path_taken_early)
         | (branch_taken_early
            & bpu_path_taken_early
            & (ifu2idu_bpu_target_i != branch_target_early));""",
    "IDU early prediction comparison"
)

# ----------------------------------------------------------------------
# EXU
# ----------------------------------------------------------------------
print("[4/7] Preparing current MEM/WB EXU...")

exu = rx1(
    exu,
    r"`ifdef SCR1_BPU_EN\s*\n"
    r"\s*// BPU interface\s*\n"
    r"\s*input\s+logic\s+idu2exu_bpu_pred_i,\s*\n"
    r"\s*input\s+logic\s+idu2exu_bpu_vld_i,\s*\n"
    r"\s*output\s+logic\s+exu2ifu_bpu_train_vld_o,\s*\n"
    r"\s*output\s+logic\s+\[`SCR1_XLEN-1:0\]\s+exu2ifu_bpu_train_pc_o,\s*\n"
    r"\s*output\s+logic\s+exu2ifu_bpu_train_taken_o,\s*\n"
    r"`endif\s*// SCR1_BPU_EN",
    """`ifdef SCR1_BPU_EN
    // BPU interface
    input   logic                               idu2exu_bpu_pred_i,
    input   logic                               idu2exu_bpu_vld_i,
    input   logic [`SCR1_XLEN-1:0]              idu2exu_bpu_target_i,
    input   logic                               idu2exu_bpu_str_i,
    input   logic                               idu2exu_bpu_steer_bypass_i,
    output  logic                               exu2ifu_bpu_train_vld_o,
    output  logic [`SCR1_XLEN-1:0]              exu2ifu_bpu_train_pc_o,
    output  logic                               exu2ifu_bpu_train_taken_o,
    output  logic [`SCR1_XLEN-1:0]              exu2ifu_bpu_train_target_o,
    output  logic                               exu2ifu_bpu_ras_push_o,
    output  logic [`SCR1_XLEN-1:0]              exu2ifu_bpu_ras_push_addr_o,
    output  logic                               exu2ifu_bpu_ras_is_return_o,
    output  logic                               exu2ifu_bpu_flush_o,
`endif // SCR1_BPU_EN""",
    "EXU BPU ports"
)

exu = rx1(
    exu,
    r"(`ifdef SCR1_BPU_EN\s*\nlogic\s+exu_bpu_pred_ff;\s*\nlogic\s+exu_bpu_vld_ff;\s*\n)",
    """\\1logic [`SCR1_XLEN-1:0]              exu_bpu_target_ff;
logic                               exu_bpu_str_ff;
logic                               exu_bpu_steer_bypass_ff;
logic                               bpu_flush_skip;
logic                               bpu_commit_pulse;
logic                               bpu_ctrl_commit;
""",
    "EXU BPU local signals"
)

exu = rx1(
    exu,
    r"(exu_bpu_pred_ff\s*<=\s*idu2exu_bpu_pred_i;\s*\n\s*exu_bpu_vld_ff\s*<=\s*idu2exu_bpu_vld_i;\s*\n)",
    """\\1        exu_bpu_target_ff        <= idu2exu_bpu_target_i;
        exu_bpu_str_ff           <= idu2exu_bpu_str_i;
        exu_bpu_steer_bypass_ff  <= idu2exu_bpu_steer_bypass_i;
""",
    "EXU BPU queue metadata latch"
)

exu = rx1(
    exu,
    r"(assign\s+exu_bpu_pred_ff\s*=\s*idu2exu_bpu_pred_i;\s*\nassign\s+exu_bpu_vld_ff\s*=\s*idu2exu_bpu_vld_i;\s*\n)",
    """\\1assign exu_bpu_target_ff       = idu2exu_bpu_target_i;
assign exu_bpu_str_ff          = idu2exu_bpu_str_i;
assign exu_bpu_steer_bypass_ff = idu2exu_bpu_steer_bypass_i;
""",
    "EXU BPU no-EXE metadata"
)

exu = rx1(
    exu,
    r"(assign\s+jb_new_pc\s*=\s*ialu_addr_res\s*&\s*SCR1_JUMP_MASK;\s*\n)",
    """\\1
`ifdef SCR1_BPU_EN
assign bpu_flush_skip =
       exu_queue_vd
     & jb_taken
     & exu_bpu_vld_ff
     & exu_bpu_pred_ff
     & (exu_bpu_str_ff | exu_bpu_steer_bypass_ff)
     & (exu_bpu_target_ff == jb_new_pc);
`endif // SCR1_BPU_EN

""",
    "EXU bpu_flush_skip"
)

exu = rx1(
    exu,
    r"(`ifdef SCR1_EARLY_BRANCH\s*\n\s*\|\s*\(exu_queue_vd\s*\n\s*&\s*exu_queue\.jump_req\s*\n)",
    """\\1`ifdef SCR1_BPU_EN
                               & ~bpu_flush_skip
`endif // SCR1_BPU_EN
""",
    "EXU EARLY jump duplicate redirect suppression"
)

exu = rx1(
    exu,
    r"`ifdef SCR1_MEM_STAGE_EN\s*\n"
    r"assign\s+exu2ifu_bpu_train_vld_o\s*=\s*\n"
    r"[\s\S]*?"
    r"assign\s+exu2ifu_bpu_train_taken_o\s*=\s*\n"
    r"\s*jb_taken;\s*\n",
    """`ifdef SCR1_MEM_STAGE_EN
assign bpu_commit_pulse = exu_queue_vd & exu_stage_rdy;
`else
assign bpu_commit_pulse = exu_queue_vd & exu_rdy;
`endif

assign bpu_ctrl_commit =
       bpu_commit_pulse
     & (exu_queue.branch_req | exu_queue.jump_req);

assign exu2ifu_bpu_train_vld_o =
       bpu_ctrl_commit
     & (exu_queue.branch_req
        | (exu_queue.jump_req
           & (exu_queue.sum2_op != SCR1_SUM2_OP_REG_IMM)));

assign exu2ifu_bpu_train_pc_o     = pc_curr_ff;
assign exu2ifu_bpu_train_taken_o  = jb_taken;
assign exu2ifu_bpu_train_target_o = jb_new_pc;

assign exu2ifu_bpu_ras_push_o =
       bpu_ctrl_commit
     & exu_queue.jump_req
     & (exu_queue.rd_addr == 5'd1);
assign exu2ifu_bpu_ras_push_addr_o = inc_pc;

assign exu2ifu_bpu_ras_is_return_o =
       bpu_ctrl_commit
     & exu_queue.jump_req
     & (exu_queue.sum2_op == SCR1_SUM2_OP_REG_IMM)
     & (exu_queue.rs1_addr == 5'd1)
     & (exu_queue.rd_addr == 5'd0);

assign exu2ifu_bpu_flush_o =
       bpu_commit_pulse & exu_queue.fencei_req;

""",
    "EXU BPU training/RAS block",
    flags=re.M
)

# ----------------------------------------------------------------------
# TOP
# ----------------------------------------------------------------------
print("[5/7] Preparing pipe_top wiring...")

top = rx1(
    top,
    r"`ifdef SCR1_BPU_EN\s*\n"
    r"// IFU -> IDU\s*\nlogic\s+ifu2idu_bpu_pred;\s*\nlogic\s+ifu2idu_bpu_vld;\s*\n\s*"
    r"// IDU -> EXU\s*\nlogic\s+idu2exu_bpu_pred;\s*\nlogic\s+idu2exu_bpu_vld;\s*\n\s*"
    r"// EXU -> IFU, BPU training\s*\nlogic\s+exu2ifu_bpu_train_vld;\s*\n"
    r"logic\s+\[`SCR1_XLEN-1:0\]\s+exu2ifu_bpu_train_pc;\s*\n"
    r"logic\s+exu2ifu_bpu_train_taken;\s*\n\s*`endif\s*// SCR1_BPU_EN",
    """`ifdef SCR1_BPU_EN
// IFU -> IDU
logic                       ifu2idu_bpu_pred;
logic                       ifu2idu_bpu_vld;
logic [`SCR1_XLEN-1:0]      ifu2idu_bpu_target;
logic                       ifu2idu_bpu_str;
logic                       ifu2idu_bpu_steer_bypass;

// IDU -> EXU
logic                       idu2exu_bpu_pred;
logic                       idu2exu_bpu_vld;
logic [`SCR1_XLEN-1:0]      idu2exu_bpu_target;
logic                       idu2exu_bpu_str;
logic                       idu2exu_bpu_steer_bypass;

// EXU -> IFU, BPU training / RAS
logic                       exu2ifu_bpu_train_vld;
logic [`SCR1_XLEN-1:0]      exu2ifu_bpu_train_pc;
logic                       exu2ifu_bpu_train_taken;
logic [`SCR1_XLEN-1:0]      exu2ifu_bpu_train_target;
logic                       exu2ifu_bpu_ras_push;
logic [`SCR1_XLEN-1:0]      exu2ifu_bpu_ras_push_addr;
logic                       exu2ifu_bpu_ras_is_return;
logic                       exu2ifu_bpu_flush;

`endif // SCR1_BPU_EN""",
    "TOP BPU signal declarations"
)

top = rx1(
    top,
    r"(// Pipeline logic\s*\n//-+\s*\n)(assign\s+stop_fetch)",
    """\\1logic                       ifu_pc_new_req;
logic [`SCR1_XLEN-1:0]      ifu_pc_new;

`ifdef SCR1_EARLY_BRANCH
assign ifu_pc_new_req = new_pc_req | idu2ifu_branch_req;
assign ifu_pc_new     = new_pc_req ? new_pc : idu2ifu_branch_target;
`else
assign ifu_pc_new_req = new_pc_req;
assign ifu_pc_new     = new_pc;
`endif // SCR1_EARLY_BRANCH

\\2""",
    "TOP redirect mux"
)

top = rx1(
    top,
    r"\.exu2ifu_pc_new_req_i\s*\(\s*new_pc_req\s*\),\s*\n\s*\.exu2ifu_pc_new_i\s*\(\s*new_pc\s*\),",
    """.exu2ifu_pc_new_req_i     (ifu_pc_new_req     ),
    .exu2ifu_pc_new_i         (ifu_pc_new         ),""",
    "TOP IFU redirect connection"
)

top = rx1(
    top,
    r"`ifdef SCR1_EARLY_BRANCH\s*\n"
    r"\s*\.ifu2idu_pc_o\s*\(\s*ifu2idu_pc\s*\),\s*\n"
    r"\s*\.idu2ifu_branch_req_i\s*\(\s*idu2ifu_branch_req\s*\),\s*\n"
    r"\s*\.idu2ifu_branch_target_i\s*\(\s*idu2ifu_branch_target\s*\),\s*\n"
    r"`endif\s*// SCR1_EARLY_BRANCH",
    """`ifdef SCR1_EARLY_BRANCH
    .ifu2idu_pc_o              (ifu2idu_pc),
`endif // SCR1_EARLY_BRANCH""",
    "TOP old IFU early ports removal"
)

top = rx1(
    top,
    r"`ifdef SCR1_BPU_EN\s*\n"
    r"\s*\.ifu2idu_bpu_pred_o\s*\(\s*ifu2idu_bpu_pred\s*\),\s*\n"
    r"\s*\.ifu2idu_bpu_vld_o\s*\(\s*ifu2idu_bpu_vld\s*\),\s*\n\s*"
    r"\s*\.exu2ifu_bpu_train_vld_i\s*\(\s*exu2ifu_bpu_train_vld\s*\),\s*\n"
    r"\s*\.exu2ifu_bpu_train_pc_i\s*\(\s*exu2ifu_bpu_train_pc\s*\),\s*\n"
    r"\s*\.exu2ifu_bpu_train_taken_i\s*\(\s*exu2ifu_bpu_train_taken\s*\),\s*\n"
    r"`endif",
    """`ifdef SCR1_BPU_EN
    .exu2ifu_bpu_flush_i         (exu2ifu_bpu_flush),
    .ifu2idu_bpu_pred_o          (ifu2idu_bpu_pred),
    .ifu2idu_bpu_vld_o           (ifu2idu_bpu_vld),
    .ifu2idu_bpu_target_o        (ifu2idu_bpu_target),
    .ifu2idu_bpu_str_o           (ifu2idu_bpu_str),
    .ifu2idu_bpu_steer_bypass_o  (ifu2idu_bpu_steer_bypass),

    .exu2ifu_bpu_train_vld_i     (exu2ifu_bpu_train_vld),
    .exu2ifu_bpu_train_pc_i      (exu2ifu_bpu_train_pc),
    .exu2ifu_bpu_train_taken_i   (exu2ifu_bpu_train_taken),
    .exu2ifu_bpu_train_target_i  (exu2ifu_bpu_train_target),
    .exu2ifu_bpu_ras_push_i      (exu2ifu_bpu_ras_push),
    .exu2ifu_bpu_ras_push_addr_i (exu2ifu_bpu_ras_push_addr),
    .exu2ifu_bpu_ras_is_return_i (exu2ifu_bpu_ras_is_return),
`endif""",
    "TOP IFU BPU wiring"
)

top = rx1(
    top,
    r"`ifdef SCR1_BPU_EN\s*\n"
    r"\s*\.ifu2idu_bpu_pred_i\s*\(\s*ifu2idu_bpu_pred\s*\),\s*\n"
    r"\s*\.ifu2idu_bpu_vld_i\s*\(\s*ifu2idu_bpu_vld\s*\),\s*\n\s*"
    r"\s*\.idu2exu_bpu_pred_o\s*\(\s*idu2exu_bpu_pred\s*\),\s*\n"
    r"\s*\.idu2exu_bpu_vld_o\s*\(\s*idu2exu_bpu_vld\s*\),\s*\n"
    r"`endif",
    """`ifdef SCR1_BPU_EN
    .ifu2idu_bpu_pred_i          (ifu2idu_bpu_pred),
    .ifu2idu_bpu_vld_i           (ifu2idu_bpu_vld),
    .ifu2idu_bpu_target_i        (ifu2idu_bpu_target),
    .ifu2idu_bpu_str_i           (ifu2idu_bpu_str),
    .ifu2idu_bpu_steer_bypass_i  (ifu2idu_bpu_steer_bypass),

    .idu2exu_bpu_pred_o          (idu2exu_bpu_pred),
    .idu2exu_bpu_vld_o           (idu2exu_bpu_vld),
    .idu2exu_bpu_target_o        (idu2exu_bpu_target),
    .idu2exu_bpu_str_o           (idu2exu_bpu_str),
    .idu2exu_bpu_steer_bypass_o  (idu2exu_bpu_steer_bypass),
`endif""",
    "TOP IDU BPU wiring"
)

top = rx1(
    top,
    r"`ifdef SCR1_BPU_EN\s*\n"
    r"\s*\.idu2exu_bpu_pred_i\s*\(\s*idu2exu_bpu_pred\s*\),\s*\n"
    r"\s*\.idu2exu_bpu_vld_i\s*\(\s*idu2exu_bpu_vld\s*\),\s*\n"
    r"\s*\.exu2ifu_bpu_train_vld_o\s*\(\s*exu2ifu_bpu_train_vld\s*\),\s*\n"
    r"\s*\.exu2ifu_bpu_train_pc_o\s*\(\s*exu2ifu_bpu_train_pc\s*\),\s*\n"
    r"\s*\.exu2ifu_bpu_train_taken_o\s*\(\s*exu2ifu_bpu_train_taken\s*\),\s*\n"
    r"`endif",
    """`ifdef SCR1_BPU_EN
    .idu2exu_bpu_pred_i             (idu2exu_bpu_pred),
    .idu2exu_bpu_vld_i              (idu2exu_bpu_vld),
    .idu2exu_bpu_target_i           (idu2exu_bpu_target),
    .idu2exu_bpu_str_i              (idu2exu_bpu_str),
    .idu2exu_bpu_steer_bypass_i     (idu2exu_bpu_steer_bypass),
    .exu2ifu_bpu_train_vld_o        (exu2ifu_bpu_train_vld),
    .exu2ifu_bpu_train_pc_o         (exu2ifu_bpu_train_pc),
    .exu2ifu_bpu_train_taken_o      (exu2ifu_bpu_train_taken),
    .exu2ifu_bpu_train_target_o     (exu2ifu_bpu_train_target),
    .exu2ifu_bpu_ras_push_o         (exu2ifu_bpu_ras_push),
    .exu2ifu_bpu_ras_push_addr_o    (exu2ifu_bpu_ras_push_addr),
    .exu2ifu_bpu_ras_is_return_o    (exu2ifu_bpu_ras_is_return),
    .exu2ifu_bpu_flush_o            (exu2ifu_bpu_flush),
`endif""",
    "TOP EXU BPU wiring"
)

print("[6/7] Static integration checks...")
checks = [
    (ifu, "ifu2idu_pc_o", "IFU PC output"),
    (ifu, "ifu_idu_bpu_path_taken", "IFU path tracking"),
    (idu, "ifu2idu_bpu_target_i", "IDU target input"),
    (idu, "bpu_path_taken_early", "IDU path compare"),
    (exu, "exu_bpu_target_ff", "EXU target metadata"),
    (exu, "bpu_flush_skip", "EXU duplicate redirect suppression"),
    (exu, "exu2ifu_bpu_ras_is_return_o", "EXU RAS output"),
    (top, "ifu_pc_new_req", "TOP unified redirect"),
    (top, "ifu2idu_bpu_steer_bypass", "TOP steer metadata"),
]
for txt, tok, label in checks:
    must_contain(txt, tok, label)
for name, txt in [("IDU", idu), ("EXU", exu), ("IFU", ifu), ("BPU", bpu), ("TOP", top)]:
    if "<<<<<<<" in txt or ">>>>>>>" in txt:
        die(f"{name}: merge marker present")

print("[7/7] Writing five integrated pipeline files...")
BPU.write_text(bpu)
IFU.write_text(ifu)
IDU.write_text(idu)
EXU.write_text(exu)
TOP.write_text(top)

print()
print("SUCCESS: latest predictor integrated. No commit was created.")
print("Run next:")
print("  git status --short")
print("  git diff --check")
print("  git diff --stat")
