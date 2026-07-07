
`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module scr1_icache(
    input  logic                            clk,
    input  logic                            rst_n,

    // IMEM router interface
    output logic                            router_req_ack_o,
    input  logic                            router_req_i,
    input  type_scr1_mem_cmd_e              router_cmd_i,
    input  logic [`SCR1_IMEM_AWIDTH-1:0]    router_addr_i,
    output logic [`SCR1_IMEM_DWIDTH-1:0]    router_rdata_o,
    output type_scr1_mem_resp_e             router_resp_o,

    // AHB/AXI bridge interface

    input  logic                            memory_req_ack_i,
    output logic                            memory_req_o,
    output type_scr1_mem_cmd_e              memory_cmd_o,
    output logic [`SCR1_IMEM_AWIDTH-1:0]    memory_addr_o,
    input  logic [`SCR1_IMEM_DWIDTH-1:0]    memory_rdata_i,
    input  type_scr1_mem_resp_e             memory_resp_i
);
    //IMEM router interface
    assign router_req_ack_o = memory_req_ack_i;
    assign router_rdata_o   = memory_rdata_i;
    assign router_resp_o    = memory_resp_i;

    // Bridge interface
    assign memory_req_o     = router_req_i;
    assign memory_cmd_o     = router_cmd_i;
    assign memory_addr_o    = router_addr_i;

endmodule