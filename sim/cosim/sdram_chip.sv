// Behavioral SDRAM chip for the co-sim: answers the exact command subset the
// real sdram_nes issues (single-word accesses, burst length 1, CL2), adapted
// from the tb_system_save model in sim/saveram (which passes against the real
// controller). Not a full SDRAM model: refresh, mode-set and precharge are
// accepted and ignored; reads complete 2 fclk after the READ command and the
// last read word stays on DQ (the controller samples once, 3 fclk after CAS,
// and issues nothing else on the bus meanwhile).
//
// Address map (non-NANO 16-bit build, as nestang_top): ACT latches
// {bank, row} = {BA[0], A[10:0]}; the READ/WRITE column A[8:0] selects the
// word, so the word address is {bank, row, col} = the byte address [21:1].
// DQM masks write lanes; reads select the lane by the controller (it picks
// the byte by address bit 0 itself).
//
// Power-up: all 0xFFFF (blank save RAM reads 0xFF, matching the firmware's
// NES/SMS/MD blank and SRAM power-up). Contents are RETAINED across resetn:
// on hardware reprogramming the FPGA does not clear the external SDRAM.
// COSIM debug port: combinational byte read of the array for expect-save-ram;
// mem is also `verilator public` for fast C++ reads. iverilog ignores both.
module sdram_chip (
    input fclk,
    input [12:0] A,
    input [1:0] BA,
    input [1:0] DQM,
    input nCS, nWE, nRAS, nCAS,
    inout [15:0] SDRAM_DQ
`ifdef COSIM
    , input [21:0] dbg_addr,
    output [7:0] dbg_data
`endif
);

reg [10:0] row_lat [0:1];
reg [15:0] mem [0:(1<<21)-1] /*verilator public*/;

integer i;
initial begin
    for (i = 0; i < (1 << 21); i = i + 1)
        mem[i] = 16'hFFFF;
end

wire [3:0] cmd = {nCS, nRAS, nCAS, nWE};
wire [20:0] word = {BA[0], row_lat[BA[0]], A[8:0]};
reg rv0 = 0, rv1 = 0;
reg [15:0] rq0 = 0, rq1 = 0;

always @(posedge fclk) begin
    if (cmd == 4'b0011)
        row_lat[BA[0]] <= A[10:0];
    else if (cmd == 4'b0100) begin
        if (!DQM[0])
            mem[word][7:0] <= SDRAM_DQ[7:0];
        if (!DQM[1])
            mem[word][15:8] <= SDRAM_DQ[15:8];
    end
    {rv1, rq1} <= {rv0, rq0};
    {rv0, rq0} <= {cmd == 4'b0101, mem[word]};
end

assign SDRAM_DQ = rv1 ? rq1 : 16'hzzzz;

`ifdef COSIM
wire [20:0] dbg_word = dbg_addr[21:1];
assign dbg_data = dbg_addr[0] ? mem[dbg_word][15:8] : mem[dbg_word][7:0];
`endif

endmodule
