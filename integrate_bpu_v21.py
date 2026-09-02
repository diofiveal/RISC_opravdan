#!/usr/bin/env python3
"""
Integrate the latest branch-predictor IFU/BPU into
integration-early-bpu-l1 while preserving EARLY_BRANCH + MEM/WB changes.

Run from the repository root:
    python3 integrate_bpu_v21.py

The script:
  * fetches origin/branch-predictor;
  * replaces only scr1_pipe_ifu.sv and scr1_pipe_bpu.sv with the new predictor versions;
  * adapts IFU with the PC sideband needed by EARLY_BRANCH;
  * extends current IDU/EXU/top with pred_target/steered/RAS interfaces;
  * keeps the current EXU MEM/WB implementation;
  * makes IDU early correction compare the path actually followed by IFU;
  * lets correctly-steered jumps/returns avoid a duplicate EXU redirect.
"""

from pathlib import Path
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
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def run(*args, check=True):
    p = subprocess.run(args, cwd=ROOT, text=True, capture_output=True)
    if check and p.returncode:
        print(p.stdout, end="")
        print(p.stderr, end="", file=sys.stderr)
        die("command failed: " + " ".join(args))
    return p.stdout


def replace_once(text, old, new, label):
    n = text.count(old)
    if n != 1:
        die(f"{label}: expected anchor exactly once, found {n}")
    return text.replace(old, new, 1)


if not PIPE.is_dir():
    die("run this script from the RISC_opravdan repository root")
for p in [IDU, EXU, TOP]:
    if not p.exists():
        die(f"missing {p}")

branch = run("git", "branch", "--show-current").strip()
if branch != "integration-early-bpu-l1":
    die(f"expected branch integration-early-bpu-l1, current branch is {branch!r}")

dirty = run("git", "status", "--porcelain", "--",
            "scr1/src/core/pipeline/scr1_pipe_idu.sv",
            "scr1/src/core/pipeline/scr1_pipe_exu.sv",
            "scr1/src/core/pipeline/scr1_pipe_ifu.sv",
            "scr1/src/core/pipeline/scr1_pipe_bpu.sv",
            "scr1/src/core/pipeline/scr1_pipe_top.sv").strip()
if dirty:
    die("target files have uncommitted changes; commit/stash them first:\n" + dirty)

print("[1/6] Fetching latest branch-predictor...")
run("git", "fetch", "myrepo", "branch-predictor")

def git_show(path):
    rel = path.relative_to(ROOT).as_posix()
    return run("git", "show", f"myrepo/branch-predictor:{rel}")

# ----------------------------------------------------------------------
# 1. Latest BPU, plus obvious C.J/C.JAL quadrant typo fix.
# ----------------------------------------------------------------------
print("[2/6] Installing latest BPU + IFU...")
bpu = git_show(BPU)
bpu = replace_once(
    bpu,
    """assign ch1_is_rvc_jump  = ch1_is_rvc & ((ch1_lo[15:13] == 3'b101) | (ch1_lo[15:13] == 3'b001))
                           & (ch1_lo[1:0] == 2'b10);""",
    """assign ch1_is_rvc_jump  = ch1_is_rvc & ((ch1_lo[15:13] == 3'b101) | (ch1_lo[15:13] == 3'b001))
                           & (ch1_lo[1:0] == 2'b01);""",
    "BPU C.J ch1 quadrant"
)
bpu = replace_once(
    bpu,
    """assign ch2_is_rvc_jump   = (ch2_lo[1:0] == 2'b10) & ((ch2_lo[15:13] == 3'b101) | (ch2_lo[15:13] == 3'b001));""",
    """assign ch2_is_rvc_jump   = (ch2_lo[1:0] == 2'b01) & ((ch2_lo[15:13] == 3'b101) | (ch2_lo[15:13] == 3'b001));""",
    "BPU C.J ch2 quadrant"
)
BPU.write_text(bpu)

# ----------------------------------------------------------------------
# 2. Latest IFU + only the EARLY_BRANCH PC sideband.
#    Early redirects use the normal new-PC port, merged in pipe_top.
# ----------------------------------------------------------------------
ifu = git_show(IFU)

ifu = replace_once(
    ifu,
    """    output  logic                                   ifu2idu_vd_o                // IFU request
`ifdef SCR1_BPU_EN""",
    """    output  logic                                   ifu2idu_vd_o                // IFU request
`ifdef SCR1_EARLY_BRANCH
    ,output logic [`SCR1_XLEN-1:0]                         ifu2idu_pc_o                // PC paired with IFU->IDU instruction
`endif // SCR1_EARLY_BRANCH
`ifdef SCR1_BPU_EN""",
    "IFU EARLY_BRANCH PC port"
)

ifu = replace_once(
    ifu,
    """// Instruction queue signals
//------------------------------------------------------------------------------
""",
    """// EARLY_BRANCH PC sideband.  The latest BPU may predict "taken" without
// actually steering the fetch stream, therefore PC follows pred_target only
// when IFU metadata says that the steer really happened.
`ifdef SCR1_EARLY_BRANCH
logic                               ifu_idu_accept;
logic                               ifu_idu_pc_advance;
logic [`SCR1_XLEN-1:0]              ifu_idu_pc_ff;
logic [`SCR1_XLEN-1:0]              ifu_idu_instr_size;
logic                               ifu_idu_bpu_path_taken;
`endif // SCR1_EARLY_BRANCH

// Instruction queue signals
//------------------------------------------------------------------------------
""",
    "IFU PC local signals"
)

ifu = replace_once(
    ifu,
    """`endif  // SCR1_NO_DEC_STAGE

`ifdef SCR1_DBG_EN
assign ifu2hdu_pbuf_rdy_o = idu2ifu_rdy_i;
`endif // SCR1_DBG_EN
""",
    """`endif  // SCR1_NO_DEC_STAGE

`ifdef SCR1_EARLY_BRANCH
assign ifu_idu_accept = ifu2idu_vd_o & idu2ifu_rdy_i;
assign ifu_idu_pc_advance = ifu_idu_accept
`ifdef SCR1_DBG_EN
                          & ~hdu2ifu_pbuf_fetch_i
`endif // SCR1_DBG_EN
                          ;
`ifdef SCR1_RVC_EXT
assign ifu_idu_instr_size = (ifu2idu_instr_o[1:0] == 2'b11)
                          ? `SCR1_XLEN'd4 : `SCR1_XLEN'd2;
`else
assign ifu_idu_instr_size = `SCR1_XLEN'd4;
`endif

`ifdef SCR1_BPU_EN
assign ifu_idu_bpu_path_taken =
       ifu2idu_bpu_vld_o
     & ifu2idu_bpu_pred_o
     & (ifu2idu_bpu_str_o | ifu2idu_bpu_steer_bypass_o);
`else
assign ifu_idu_bpu_path_taken = 1'b0;
`endif // SCR1_BPU_EN

always_ff @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        ifu_idu_pc_ff <= SCR1_RST_VECTOR;
    end else if (exu2ifu_pc_new_req_i) begin
        // pipe_top also routes an IDU EARLY_BRANCH correction through this port.
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

`ifdef SCR1_DBG_EN
assign ifu2hdu_pbuf_rdy_o = idu2ifu_rdy_i;
`endif // SCR1_DBG_EN
""",
    "IFU PC tracker"
)
IFU.write_text(ifu)

# ----------------------------------------------------------------------
# 3. Patch current IDU: keep EARLY_BRANCH, add new predictor metadata.
# ----------------------------------------------------------------------
print("[3/6] Patching current IDU...")
idu = IDU.read_text()

idu = replace_once(
    idu,
    """`ifdef SCR1_BPU_EN
    input   logic                          ifu2idu_bpu_pred_i,
    input   logic                          ifu2idu_bpu_vld_i,
    output  logic                          idu2exu_bpu_pred_o,
    output  logic                          idu2exu_bpu_vld_o,
`endif""",
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

idu = replace_once(
    idu,
    """logic                               idu_accept;                // for handshake
`endif //SCR1_EARLY_BRANCH""",
    """logic                               idu_accept;                // for handshake
`ifdef SCR1_BPU_EN
logic                               bpu_path_taken_early;
`endif // SCR1_BPU_EN
`endif //SCR1_EARLY_BRANCH""",
    "IDU BPU path signal"
)

idu = replace_once(
    idu,
    """assign idu2exu_bpu_pred_o = ifu2idu_bpu_pred_i;
assign idu2exu_bpu_vld_o  = ifu2idu_bpu_vld_i;

`endif // SCR1_BPU_EN""",
    """assign idu2exu_bpu_pred_o         = ifu2idu_bpu_pred_i;
assign idu2exu_bpu_vld_o          = ifu2idu_bpu_vld_i;
assign idu2exu_bpu_target_o       = ifu2idu_bpu_target_i;
assign idu2exu_bpu_str_o          = ifu2idu_bpu_str_i;
assign idu2exu_bpu_steer_bypass_o = ifu2idu_bpu_steer_bypass_i;
`ifdef SCR1_EARLY_BRANCH
// Important: "predicted taken" is not the same as "IFU followed the target".
// The new IFU can suppress/delay a steer.  Early correction compares against
// the path which was actually selected by fetch.
assign bpu_path_taken_early =
       ifu2idu_bpu_vld_i
     & ifu2idu_bpu_pred_i
     & (ifu2idu_bpu_str_i | ifu2idu_bpu_steer_bypass_i);
`endif // SCR1_EARLY_BRANCH

`endif // SCR1_BPU_EN""",
    "IDU BPU pass-through"
)

idu = replace_once(
    idu,
    """    branch_req_early =
        branch_taken_early
        != (ifu2idu_bpu_vld_i & ifu2idu_bpu_pred_i);""",
    """    // Correct when direction differs from the path actually followed,
    // or when both are taken but the predicted target itself was wrong.
    branch_req_early =
           (branch_taken_early != bpu_path_taken_early)
         | (branch_taken_early
            & bpu_path_taken_early
            & (ifu2idu_bpu_target_i != branch_target_early));""",
    "IDU early mispredict comparison"
)
IDU.write_text(idu)

# ----------------------------------------------------------------------
# 4. Patch current MEM/WB EXU rather than replacing it.
# ----------------------------------------------------------------------
print("[4/6] Patching current MEM/WB EXU...")
exu = EXU.read_text()

exu = replace_once(
    exu,
    """`ifdef SCR1_BPU_EN
    // BPU interface
    input   logic                               idu2exu_bpu_pred_i,
    input   logic                               idu2exu_bpu_vld_i,
    output  logic                               exu2ifu_bpu_train_vld_o,
    output  logic [`SCR1_XLEN-1:0]              exu2ifu_bpu_train_pc_o,
    output  logic                               exu2ifu_bpu_train_taken_o,
`endif // SCR1_BPU_EN""",
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

exu = replace_once(
    exu,
    """logic                               exu_bpu_pred_ff;
logic                               exu_bpu_vld_ff;
`ifndef SCR1_EARLY_BRANCH""",
    """logic                               exu_bpu_pred_ff;
logic                               exu_bpu_vld_ff;
logic [`SCR1_XLEN-1:0]              exu_bpu_target_ff;
logic                               exu_bpu_str_ff;
logic                               exu_bpu_steer_bypass_ff;
logic                               bpu_flush_skip;
logic                               bpu_commit_pulse;
logic                               bpu_ctrl_commit;
`ifndef SCR1_EARLY_BRANCH""",
    "EXU BPU local signals"
)

exu = replace_once(
    exu,
    """        exu_bpu_pred_ff          <= idu2exu_bpu_pred_i;
        exu_bpu_vld_ff           <= idu2exu_bpu_vld_i;
`endif // SCR1_BPU_EN""",
    """        exu_bpu_pred_ff          <= idu2exu_bpu_pred_i;
        exu_bpu_vld_ff           <= idu2exu_bpu_vld_i;
        exu_bpu_target_ff        <= idu2exu_bpu_target_i;
        exu_bpu_str_ff           <= idu2exu_bpu_str_i;
        exu_bpu_steer_bypass_ff  <= idu2exu_bpu_steer_bypass_i;
`endif // SCR1_BPU_EN""",
    "EXU BPU queue latch"
)

exu = replace_once(
    exu,
    """assign exu_bpu_pred_ff = idu2exu_bpu_pred_i;
assign exu_bpu_vld_ff  = idu2exu_bpu_vld_i;
`endif""",
    """assign exu_bpu_pred_ff         = idu2exu_bpu_pred_i;
assign exu_bpu_vld_ff          = idu2exu_bpu_vld_i;
assign exu_bpu_target_ff       = idu2exu_bpu_target_i;
assign exu_bpu_str_ff          = idu2exu_bpu_str_i;
assign exu_bpu_steer_bypass_ff = idu2exu_bpu_steer_bypass_i;
`endif""",
    "EXU BPU no-EXE passthrough"
)

# Correctly followed taken control transfer: don't issue a second redirect.
exu = replace_once(
    exu,
    """assign jb_new_pc    = ialu_addr_res & SCR1_JUMP_MASK;

`ifdef SCR1_BPU_EN""",
    """assign jb_new_pc    = ialu_addr_res & SCR1_JUMP_MASK;

`ifdef SCR1_BPU_EN
assign bpu_flush_skip =
       exu_queue_vd
     & jb_taken
     & exu_bpu_vld_ff
     & exu_bpu_pred_ff
     & (exu_bpu_str_ff | exu_bpu_steer_bypass_ff)
     & (exu_bpu_target_ff == jb_new_pc);

""",
    "EXU flush-skip"
)

# Preserve EARLY_BRANCH branch verification, but avoid re-redirect for
# a jump/return whose target was already followed by IFU.
exu = replace_once(
    exu,
    """                            | (exu_queue_vd
                               & exu_queue.jump_req
`ifdef SCR1_MEM_STAGE_EN""",
    """                            | (exu_queue_vd
                               & exu_queue.jump_req
`ifdef SCR1_BPU_EN
                               & ~bpu_flush_skip
`endif // SCR1_BPU_EN
`ifdef SCR1_MEM_STAGE_EN""",
    "EXU EARLY jump redirect suppression"
)

old_train = """`ifdef SCR1_MEM_STAGE_EN
assign exu2ifu_bpu_train_vld_o =
       exu_queue_vd
     & exu_stage_rdy
     & (exu_queue.branch_req | exu_queue.jump_req);
`else
assign exu2ifu_bpu_train_vld_o =
       exu_queue_vd
     & exu_rdy
     & (exu_queue.branch_req | exu_queue.jump_req);
`endif

assign exu2ifu_bpu_train_pc_o =
       pc_curr_ff;
assign exu2ifu_bpu_train_taken_o =
       jb_taken;
"""
new_train = """`ifdef SCR1_MEM_STAGE_EN
assign bpu_commit_pulse = exu_queue_vd & exu_stage_rdy;
`else
assign bpu_commit_pulse = exu_queue_vd & exu_rdy;
`endif

assign bpu_ctrl_commit = bpu_commit_pulse
                       & (exu_queue.branch_req | exu_queue.jump_req);

// Do not train the direction BHT on register-indirect JALR.  Returns are
// handled by the RAS below; ordinary JALR targets are not stable BHT targets.
assign exu2ifu_bpu_train_vld_o =
       bpu_ctrl_commit
     & (exu_queue.branch_req
        | (exu_queue.jump_req
           & (exu_queue.sum2_op != SCR1_SUM2_OP_REG_IMM)));

assign exu2ifu_bpu_train_pc_o     = pc_curr_ff;
assign exu2ifu_bpu_train_taken_o  = jb_taken;
assign exu2ifu_bpu_train_target_o = jb_new_pc;

// Call/return training for the new 8-entry RAS.
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

// Flush prediction state when FENCE.I itself reaches the EXU commit point.
assign exu2ifu_bpu_flush_o =
       bpu_commit_pulse & exu_queue.fencei_req;
"""
exu = replace_once(exu, old_train, new_train, "EXU BPU training/RAS")

EXU.write_text(exu)

# ----------------------------------------------------------------------
# 5. Patch top: merge early correction into normal IFU new-PC interface.
# ----------------------------------------------------------------------
print("[5/6] Patching pipe_top...")
top = TOP.read_text()

top = replace_once(
    top,
    """`ifdef SCR1_BPU_EN
// IFU -> IDU
logic                       ifu2idu_bpu_pred;
logic                       ifu2idu_bpu_vld;

// IDU -> EXU
logic                       idu2exu_bpu_pred;
logic                       idu2exu_bpu_vld;

// EXU -> IFU, BPU training
logic                       exu2ifu_bpu_train_vld;
logic [`SCR1_XLEN-1:0]      exu2ifu_bpu_train_pc;
logic                       exu2ifu_bpu_train_taken;

`endif // SCR1_BPU_EN""",
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
    "TOP BPU signals"
)

top = replace_once(
    top,
    """// Pipeline logic
//-------------------------------------------------------------------------------
assign stop_fetch""",
    """// Pipeline logic
//-------------------------------------------------------------------------------
// All redirects enter the latest IFU through ONE interface.
// An older EXU redirect/trap wins over a simultaneously decoded younger branch.
logic                       ifu_pc_new_req;
logic [`SCR1_XLEN-1:0]      ifu_pc_new;
`ifdef SCR1_EARLY_BRANCH
assign ifu_pc_new_req = new_pc_req | idu2ifu_branch_req;
assign ifu_pc_new     = new_pc_req ? new_pc : idu2ifu_branch_target;
`else
assign ifu_pc_new_req = new_pc_req;
assign ifu_pc_new     = new_pc;
`endif // SCR1_EARLY_BRANCH

assign stop_fetch""",
    "TOP unified redirect mux"
)

top = replace_once(
    top,
    """.exu2ifu_pc_new_req_i     (new_pc_req         ),
    .exu2ifu_pc_new_i         (new_pc             ),""",
    """.exu2ifu_pc_new_req_i     (ifu_pc_new_req     ),
    .exu2ifu_pc_new_i         (ifu_pc_new         ),""",
    "TOP IFU new-PC connection"
)

top = replace_once(
    top,
    """`ifdef SCR1_EARLY_BRANCH
    .ifu2idu_pc_o            (ifu2idu_pc),
    .idu2ifu_branch_req_i    (idu2ifu_branch_req),
    .idu2ifu_branch_target_i (idu2ifu_branch_target),
`endif // SCR1_EARLY_BRANCH
`ifdef SCR1_BPU_EN
    .ifu2idu_bpu_pred_o        (ifu2idu_bpu_pred),
    .ifu2idu_bpu_vld_o         (ifu2idu_bpu_vld),

    .exu2ifu_bpu_train_vld_i   (exu2ifu_bpu_train_vld),
    .exu2ifu_bpu_train_pc_i    (exu2ifu_bpu_train_pc),
    .exu2ifu_bpu_train_taken_i (exu2ifu_bpu_train_taken),
`endif""",
    """`ifdef SCR1_EARLY_BRANCH
    .ifu2idu_pc_o              (ifu2idu_pc),
`endif // SCR1_EARLY_BRANCH
`ifdef SCR1_BPU_EN
    .exu2ifu_bpu_flush_i       (exu2ifu_bpu_flush),
    .ifu2idu_bpu_pred_o        (ifu2idu_bpu_pred),
    .ifu2idu_bpu_vld_o         (ifu2idu_bpu_vld),
    .ifu2idu_bpu_target_o      (ifu2idu_bpu_target),
    .ifu2idu_bpu_str_o         (ifu2idu_bpu_str),
    .ifu2idu_bpu_steer_bypass_o(ifu2idu_bpu_steer_bypass),

    .exu2ifu_bpu_train_vld_i   (exu2ifu_bpu_train_vld),
    .exu2ifu_bpu_train_pc_i    (exu2ifu_bpu_train_pc),
    .exu2ifu_bpu_train_taken_i (exu2ifu_bpu_train_taken),
    .exu2ifu_bpu_train_target_i(exu2ifu_bpu_train_target),
    .exu2ifu_bpu_ras_push_i    (exu2ifu_bpu_ras_push),
    .exu2ifu_bpu_ras_push_addr_i(exu2ifu_bpu_ras_push_addr),
    .exu2ifu_bpu_ras_is_return_i(exu2ifu_bpu_ras_is_return),
`endif""",
    "TOP IFU BPU connections"
)

top = replace_once(
    top,
    """    .ifu2idu_bpu_pred_i      (ifu2idu_bpu_pred  ),
    .ifu2idu_bpu_vld_i       (ifu2idu_bpu_vld   ),

    .idu2exu_bpu_pred_o      (idu2exu_bpu_pred  ),
    .idu2exu_bpu_vld_o       (idu2exu_bpu_vld   ),""",
    """    .ifu2idu_bpu_pred_i       (ifu2idu_bpu_pred),
    .ifu2idu_bpu_vld_i        (ifu2idu_bpu_vld),
    .ifu2idu_bpu_target_i     (ifu2idu_bpu_target),
    .ifu2idu_bpu_str_i        (ifu2idu_bpu_str),
    .ifu2idu_bpu_steer_bypass_i(ifu2idu_bpu_steer_bypass),

    .idu2exu_bpu_pred_o       (idu2exu_bpu_pred),
    .idu2exu_bpu_vld_o        (idu2exu_bpu_vld),
    .idu2exu_bpu_target_o     (idu2exu_bpu_target),
    .idu2exu_bpu_str_o        (idu2exu_bpu_str),
    .idu2exu_bpu_steer_bypass_o(idu2exu_bpu_steer_bypass),""",
    "TOP IDU BPU connections"
)

top = replace_once(
    top,
    """    .idu2exu_bpu_pred_i             (idu2exu_bpu_pred        ),
    .idu2exu_bpu_vld_i              (idu2exu_bpu_vld         ),
    .exu2ifu_bpu_train_vld_o        (exu2ifu_bpu_train_vld   ),
    .exu2ifu_bpu_train_pc_o         (exu2ifu_bpu_train_pc    ),
    .exu2ifu_bpu_train_taken_o      (exu2ifu_bpu_train_taken ),
`endif""",
    """    .idu2exu_bpu_pred_i             (idu2exu_bpu_pred),
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
    "TOP EXU BPU connections"
)

TOP.write_text(top)

print("[6/6] Basic checks...")
for p in TARGETS:
    txt = p.read_text()
    if "<<<<<<<" in txt or ">>>>>>>" in txt:
        die(f"merge marker found in {p}")

print()
print("Integration written successfully.")
print("Review with:")
print("  git diff -- scr1/src/core/pipeline")
print()
print("Important: this script changes working-tree files only; it does NOT commit or push.")
