// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Symbol table implementation internals

#include "Vscr1_top_tb_ahb__pch.h"
#include "Vscr1_top_tb_ahb.h"
#include "Vscr1_top_tb_ahb___024root.h"
#include "Vscr1_top_tb_ahb___024unit.h"

// FUNCTIONS
Vscr1_top_tb_ahb__Syms::~Vscr1_top_tb_ahb__Syms()
{
}

Vscr1_top_tb_ahb__Syms::Vscr1_top_tb_ahb__Syms(VerilatedContext* contextp, const char* namep, Vscr1_top_tb_ahb* modelp)
    : VerilatedSyms{contextp}
    // Setup internal state of the Syms class
    , __Vm_modelp{modelp}
    // Setup module instances
    , TOP{this, namep}
{
    // Configure time unit / time precision
    _vm_contextp__->timeunit(-12);
    _vm_contextp__->timeprecision(-12);
    // Setup each module's pointers to their submodules
    // Setup each module's pointer back to symbol table (for public functions)
    TOP.__Vconfigure(true);
}
