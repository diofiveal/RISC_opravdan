`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module scr1_dcache (
    input  logic                         clk,
    input  logic                         rst_n,

    // DMEM router interface
    input  logic                         router_req_i,
    input  type_scr1_mem_cmd_e           router_cmd_i,
    input  type_scr1_mem_width_e         router_width_i,
    input  logic [`SCR1_DMEM_AWIDTH-1:0] router_addr_i,
    input  logic [`SCR1_DMEM_DWIDTH-1:0] router_wdata_i,
    output logic                         router_req_ack_o,
    output logic [`SCR1_DMEM_DWIDTH-1:0] router_rdata_o,
    output type_scr1_mem_resp_e          router_resp_o,

    // AHB / AXI bridge interface
    output logic                         memory_req_o,
    output type_scr1_mem_cmd_e           memory_cmd_o,
    output type_scr1_mem_width_e         memory_width_o,
    output logic [`SCR1_DMEM_AWIDTH-1:0] memory_addr_o,
    output logic [`SCR1_DMEM_DWIDTH-1:0] memory_wdata_o,
    input  logic                         memory_req_ack_i,
    input  logic [`SCR1_DMEM_DWIDTH-1:0] memory_rdata_i,
    input  type_scr1_mem_resp_e          memory_resp_i
);

    // Request path: DMEM router -> dcache -> memory bridge
    assign memory_req_o      = router_req_i;
    assign memory_cmd_o      = router_cmd_i;
    assign memory_width_o    = router_width_i;
    assign memory_addr_o     = router_addr_i;
    assign memory_wdata_o    = router_wdata_i;

    // Response path: memory bridge -> dcache -> DMEM router
    assign router_req_ack_o  = memory_req_ack_i;
    assign router_rdata_o    = memory_rdata_i;
    assign router_resp_o     = memory_resp_i;

endmodule : scr1_dcache