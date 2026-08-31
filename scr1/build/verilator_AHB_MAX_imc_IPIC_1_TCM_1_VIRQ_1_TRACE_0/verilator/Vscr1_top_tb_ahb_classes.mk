# Verilated -*- Makefile -*-
# DESCRIPTION: Verilator output: Make include file with class lists
#
# This file lists generated Verilated files, for including in higher level makefiles.
# See Vscr1_top_tb_ahb.mk for the caller.

### Switches...
# C11 constructs required?  0/1 (always on now)
VM_C11 = 1
# Timing enabled?  0/1
VM_TIMING = 0
# Coverage output mode?  0/1 (from --coverage)
VM_COVERAGE = 0
# Parallel builds?  0/1 (from --output-split)
VM_PARALLEL_BUILDS = 1
# Tracing output mode?  0/1 (from --trace/--trace-fst)
VM_TRACE = 0
# Tracing output mode in VCD format?  0/1 (from --trace)
VM_TRACE_VCD = 0
# Tracing output mode in FST format?  0/1 (from --trace-fst)
VM_TRACE_FST = 0

### Object file lists...
# Generated module classes, fast-path, compile with highest optimization
VM_CLASSES_FAST += \
	Vscr1_top_tb_ahb \
	Vscr1_top_tb_ahb___024root__DepSet_h46df07de__0 \
	Vscr1_top_tb_ahb___024root__DepSet_h757a5413__0 \
	Vscr1_top_tb_ahb___024root__DepSet_h757a5413__1 \

# Generated module classes, non-fast-path, compile with low/medium optimization
VM_CLASSES_SLOW += \
	Vscr1_top_tb_ahb__ConstPool_0 \
	Vscr1_top_tb_ahb___024root__Slow \
	Vscr1_top_tb_ahb___024root__DepSet_h46df07de__0__Slow \
	Vscr1_top_tb_ahb___024root__DepSet_h757a5413__0__Slow \
	Vscr1_top_tb_ahb___024root__DepSet_h757a5413__1__Slow \
	Vscr1_top_tb_ahb___024unit__Slow \
	Vscr1_top_tb_ahb___024unit__DepSet_h792097e3__0__Slow \

# Generated support classes, fast-path, compile with highest optimization
VM_SUPPORT_FAST += \

# Generated support classes, non-fast-path, compile with low/medium optimization
VM_SUPPORT_SLOW += \
	Vscr1_top_tb_ahb__Syms \

# Global classes, need linked once per executable, fast-path, compile with highest optimization
VM_GLOBAL_FAST += \
	verilated \
	verilated_threads \

# Global classes, need linked once per executable, non-fast-path, compile with low/medium optimization
VM_GLOBAL_SLOW += \


# Verilated -*- Makefile -*-
