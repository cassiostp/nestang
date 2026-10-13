// Simulation stand-in for the VHDL eseopll (src/opll/eseopll.vhd), which
// the Verilog simulators cannot compile. VRC7 games run with silent FM in
// simulation; only the Gowin builds use the real VM2413. Port order matches
// the eseopll entity declaration.
module eseopll (
	input         clk21m,
	input         reset,
	input         clkena,
	input         enawait,
	input         req,
	output        ack,
	input         wrt,
	input  [15:0] adr,
	input   [7:0] dbo,
	output [13:0] wav
);
	assign ack = req;
	assign wav = 14'd0;
endmodule
