// Save-channel unit test for sdram_nes: the req/ack byte client that hangs the
// NES WRAM window (linear 0x3C0000) off the CPU/PPU slot, verified against a
// behavioral 16-bit SDRAM. Covers ack'd byte writes/reads (incl. the odd/even
// byte lane and row crossing inside blk0..15), save traffic running alongside a
// CPU read stream (arbitration), and that a save transaction never issues twice.
// Run with run.sh (iverilog; configPackage is stubbed here).

`timescale 1ns/1ps

package configPackage;
    localparam SDRAM_DATA_WIDTH = 16;
    localparam SDRAM_ROW_WIDTH  = 13;
endpackage

module tb_sdram_save;

localparam [21:0] WRAM = 22'h3C0000;

reg clk = 0;
always #7.7555 clk = ~clk;            // fclk 64.47 Mhz half period
integer ph = 0;
always @(posedge clk) ph <= ph == 5 ? 0 : ph + 1;
wire clkref = ph < 3;                 // once per 6-fclk window, like clk=fclk/3

reg resetn = 0;

wire busy;
wire [15:0] SDRAM_DQ;

// save client side
reg  [21:0] sv_addr = 0;
reg  [7:0]  sv_din = 0;
reg         sv_we = 0, sv_req = 0;
wire        sv_ack;
wire [7:0]  sv_dout;

// CPU-side ports, driven by the tasks and the stream below
reg  [21:0] addrB_t = 0;
reg  [7:0]  dinB_t = 0;
reg         weB_t = 0, oeB_t = 0;
wire        oeB = oeB_t | oeB_s;
reg         cpu_stream = 0, oeB_s = 0;
integer     cph = 0;
always @(posedge clk) begin
    cph <= cph + 1;
    if (cpu_stream && (cph % 6 == 0)) oeB_s <= ~oeB_s;   // a fetch-ish every 6 clk
end

sdram_nes dut (
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_nCS(nCS),
    .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_CKE(cke),
    .clk(clk), .clkref(clkref), .resetn(resetn), .busy(busy),
    .addrA(22'h0), .weA(1'b0), .dinA(8'h0), .oeA(1'b0), .doutA(),
    .addrB(cpu_stream && oeB_s && ~oeB_t ? 22'h100 : addrB_t),
    .weB(weB_t), .dinB(dinB_t), .oeB(oeB), .doutB(doutB),
    .rv_addr(20'h0), .rv_din(16'h0), .rv_ds(2'b00), .rv_dout(), .rv_req(1'b0),
    .rv_req_ack(), .rv_we(1'b0),
    .SDRAM_DQM(DQM),
    .sv_addr(sv_addr), .sv_din(sv_din), .sv_we(sv_we),
    .sv_req(sv_req), .sv_ack(sv_ack), .sv_dout(sv_dout)
);
wire [SDRAM_ROW_WIDTH-1:0] A;
wire [1:0] BA;
wire nCS, nWE, nRAS, nCAS;
wire [7:0] doutB;
wire [1:0] DQM;

// ---- behavioral SDRAM: 2 banks, activate latches the row, CL2 read ----
reg [10:0] row_lat [0:1];
reg [15:0] mem [0:(1<<21)-1];
wire [3:0] cmd = {nCS, nRAS, nCAS, nWE};
wire [20:0] word = {BA[0], row_lat[BA[0]], A[8:0]};  // controller: row in A[10:0],
                                                     // 16-bit column word in A[8:0]
reg rv0 = 0, rv1 = 0;
reg [15:0] rq0 = 0, rq1 = 0;
wire rd_fire = (cmd == 4'b0101);
wire wr_fire = (cmd == 4'b0100);

always @(posedge clk) begin
    if (cmd == 4'b0011)                       // activate
        row_lat[BA[0]] <= A[10:0];
    else if (wr_fire) begin                   // write, byte-masked
        if (!DQM[0]) mem[word][7:0]   <= SDRAM_DQ[7:0];
        if (!DQM[1]) mem[word][15:8]  <= SDRAM_DQ[15:8];
    end
    {rv1, rq1} <= {rv0, rq0};
    {rv0, rq0} <= {rd_fire, mem[word]};       // CL2: drives two clocks later
end
assign SDRAM_DQ = rv1 ? rq1 : 16'hzzzz;

// the save client must not accept a second request before the ack
integer errs = 0;
reg sv_req_d = 0;
always @(posedge clk) begin
    sv_req_d <= sv_req;
    if (sv_req != sv_req_d && sv_req_d != sv_ack) begin
        errs = errs + 1;
        $display("FAIL: two save requests at once t=%0t ack=%b we=%b addr=%06h", $time, sv_ack, sv_we, sv_addr);
    end
end

// ---- client tasks ----
task done_ok;
    integer t;
begin
    t = 0;
    @(posedge clk);                         // let this task's req toggle land first
    while (sv_ack != sv_req && t < 20000) begin @(posedge clk); t = t + 1; end
    if (sv_ack != sv_req) begin
        errs = errs + 1;
        $display("FAIL: save ack timeout");
    end
end
endtask

task sv_write(input [21:0] a, input [7:0] d);
begin
    @(posedge clk); sv_addr <= a; sv_din <= d; sv_we <= 1; sv_req <= ~sv_req;
    done_ok;
end
endtask

task sv_read(input [21:0] a, input [7:0] e);
    reg [7:0] got;
begin
    @(posedge clk); sv_addr <= a; sv_we <= 0; sv_req <= ~sv_req;
    done_ok;
    repeat (14) @(posedge clk);   // data follows the ack by cycle[4] of the frame
    got = sv_dout;
    if (got !== e) begin
        errs = errs + 1;
        $display("FAIL: sv read [%06x] = %02x, expected %02x", a, got, e);
    end
end
endtask

function [7:0] pat(input integer i);
    pat = (i * 7 + 13) & 8'hFF;
endfunction

integer k;

initial begin
    // the SDRAM model comes up as X, like the real chip's contents
    for (k = 0; k < (1<<21); k = k + 1) mem[k] = 8'hzz;

    repeat (10) @(posedge clk);
    resetn = 1;
    wait (busy == 0);                           // init ends after 200 us
    repeat (20) @(posedge clk);

    // 1. byte writes/reads across blocks 0..15, incl. row crossings
    for (k = 0; k < 128; k = k + 1)
        sv_write(WRAM + k[21:0] * 63, pat(k));
    for (k = 0; k < 128; k = k + 1)
        sv_read(WRAM + k[21:0] * 63, pat(k));

    // 2. byte lane: a write at an odd address must not disturb its neighbour
    sv_write(WRAM + 22'h0100, 8'hAA);
    sv_write(WRAM + 22'h0101, 8'h55);
    sv_read(WRAM + 22'h0100, 8'hAA);
    sv_read(WRAM + 22'h0101, 8'h55);

    // 3. save traffic alongside a CPU read stream: nothing is lost or skewed
    @(posedge clk); addrB_t <= 22'h100; dinB_t <= 8'h77; weB_t <= 1;
    done_ok_cpu; @(posedge clk); weB_t <= 0;   // held until the frame took it, like the core
    cpu_stream = 1;
    for (k = 0; k < 16; k = k + 1) begin
        sv_write(WRAM + 22'h1000 + k[21:0], 8'h30 + k[7:0]);
        sv_read (WRAM + 22'h1000 + k[21:0], 8'h30 + k[7:0]);
    end
    @(posedge clk); addrB_t <= 22'h100; oeB_t <= 1;
    done_ok_cpu; @(posedge clk); oeB_t <= 0;   // held until captured, like a stalled CPU
    repeat (40) @(posedge clk);
    if (doutB !== 8'h77) begin
        errs = errs + 1;
        $display("FAIL: cpu read through the stream = %02x, expected 77", doutB);
    end
    cpu_stream = 0; oeB_s = 0;

    // 4. a dump-like read burst: write then read one whole block, byte exact
    for (k = 0; k < 512; k = k + 1) sv_write(WRAM + k[21:0], pat(k));
    for (k = 0; k < 512; k = k + 1) sv_read(WRAM + k[21:0], pat(k));

    if (errs == 0) $display("tb_sdram_save: PASS");
    else $fatal(1, "tb_sdram_save: FAIL, %0d errors", errs);
    $finish;
end

task done_ok_cpu;
    integer t;
begin
    t = 0;
    @(posedge clk);
    // CPU port has no ack; a request rides the next frame (6 phases x 6 fclk
    // here), and read data lands at cycle[4] of it. Two frames is generous.
    repeat (100) @(posedge clk);
end
endtask

endmodule
