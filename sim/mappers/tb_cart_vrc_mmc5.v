// Regression for the re-enabled Konami VRC family and MMC5.
//
// The full cart.sv does not parse under Icarus (pre-existing SystemVerilog
// in other mapper files), so this bench instantiates the VRC24, VRC6 and
// MMC5 modules on the same tri-state buses cart.sv wires them to, with the
// same enable expressions. run.sh grep-gates keep cart.sv, build.tcl and
// nestang_top.sv wired the way this bench assumes; Gowin CI and the
// Verilator sim elaborate the real cart_top.
//
// Checks:
//   mapper 23 (VRC2/4): PRG and CHR bank registers move the bus addresses
//   mapper 24 (VRC6):   square channel 1 makes expansion audio non-silent
//   mapper 5  (MMC5):   PRG banking (mode 3), ExRAM mode-2 read/write,
//                       and the $5205/$5206 hardware multiplier
`timescale 1ns/1ps
module tb_cart_vrc_mmc5;
	reg clk = 0;
	always #5 clk = ~clk;

	reg ce = 0, ppu_ce = 0;
	reg [7:0] mapper = 0;
	wire [31:0] flags = {16'd0, 3'd6, 3'd6, 2'd0, mapper};
	reg [15:0] prg_ain = 0;
	reg prg_read = 0, prg_write = 0;
	reg [7:0] prg_din = 0;
	reg chr_read = 0, chr_write = 0;
	reg [7:0] chr_din = 0;
	reg [13:0] chr_ain = 0;
	reg [15:0] audio_in = 16'h8000;

	// cart.sv's shared mapper buses
	tri0 prg_allow_b, vram_a10_b, vram_ce_b, chr_allow_b, irq_b;
	tri0 [21:0] prg_addr_b, chr_addr_b;
	tri0 [15:0] flags_out_b, audio_out_b;
	tri1 [7:0] prg_dout_b, chr_dout_b;

	wire [15:0] vrc6_audio, vrc7_audio_unused;
	wire en_vrc24 = (mapper==21)|(mapper==22)|(mapper==23)|(mapper==25)|(mapper==27);
	wire en_vrc6  = (mapper==24)|(mapper==26);
	wire en_mmc5  = (mapper==5);

	VRC24 vrc24 (
		.clk(clk), .ce(ce), .enable(en_vrc24), .flags(flags),
		.prg_ain(prg_ain), .prg_aout_b(prg_addr_b),
		.prg_read(prg_read), .prg_write(prg_write), .prg_din(prg_din),
		.prg_dout_b(prg_dout_b), .prg_allow_b(prg_allow_b),
		.chr_ain(chr_ain), .chr_aout_b(chr_addr_b), .chr_read(chr_read),
		.chr_allow_b(chr_allow_b), .vram_a10_b(vram_a10_b),
		.vram_ce_b(vram_ce_b), .irq_b(irq_b), .flags_out_b(flags_out_b),
		.audio_in(audio_in), .audio_b(audio_out_b)
	);

	VRC6 vrc6 (
		.clk(clk), .ce(ce), .enable(en_vrc6), .flags(flags),
		.prg_ain(prg_ain), .prg_aout_b(prg_addr_b),
		.prg_read(prg_read), .prg_write(prg_write), .prg_din(prg_din),
		.prg_dout_b(prg_dout_b), .prg_allow_b(prg_allow_b),
		.chr_ain(chr_ain), .chr_aout_b(chr_addr_b), .chr_read(chr_read),
		.chr_allow_b(chr_allow_b), .vram_a10_b(vram_a10_b),
		.vram_ce_b(vram_ce_b), .irq_b(irq_b), .flags_out_b(flags_out_b),
		.audio_in(vrc6_audio), .audio_b(audio_out_b)
	);

	vrc6_mixed snd_vrc6 (
		.clk(clk), .ce(ce), .enable(en_vrc6), .wren(prg_write),
		.addr_invert(mapper==8'd26), .addr_in(prg_ain), .data_in(prg_din),
		.audio_in(audio_in), .audio_out(vrc6_audio)
	);

	MMC5 mmc5 (
		.clk(clk), .ce(ce), .enable(en_mmc5), .flags(flags),
		.prg_ain(prg_ain), .prg_aout_b(prg_addr_b),
		.prg_read(prg_read), .prg_write(prg_write), .prg_din(prg_din),
		.prg_dout_b(prg_dout_b), .prg_allow_b(prg_allow_b),
		.chr_ain(chr_ain), .chr_aout_b(chr_addr_b), .chr_read(chr_read),
		.chr_allow_b(chr_allow_b), .vram_a10_b(vram_a10_b),
		.vram_ce_b(vram_ce_b), .irq_b(irq_b), .flags_out_b(flags_out_b),
		.audio_in(audio_in), .audio_b(audio_out_b),
		.audio_dout(8'h00), .chr_din(chr_din), .chr_write(chr_write),
		.chr_dout_b(chr_dout_b), .ppu_ce(ppu_ce), .ppuflags(20'd0)
	);

	integer errors = 0;

	task set_mapper(input [7:0] m);
		begin
			mapper = 0;                 // disabled: registers reset
			repeat (4) @(posedge clk);
			mapper = m;
			repeat (2) @(posedge clk);
		end
	endtask

	task cpu_write(input [15:0] addr, input [7:0] data);
		begin
			@(negedge clk);
			prg_ain = addr; prg_din = data; prg_write = 1; ce = 1;
			@(negedge clk);
			prg_write = 0; ce = 0;
		end
	endtask

	task check22(input [21:0] got, input [21:0] want, input [8*48-1:0] what);
		begin
			if (got !== want) begin
				errors = errors + 1;
				$display("FAIL %0s: got %h want %h", what, got, want);
			end else
				$display("ok   %0s = %h", what, got);
		end
	endtask

	task check8(input [7:0] got, input [7:0] want, input [8*48-1:0] what);
		begin
			if (got !== want) begin
				errors = errors + 1;
				$display("FAIL %0s: got %h want %h", what, got, want);
			end else
				$display("ok   %0s = %h", what, got);
		end
	endtask

	reg sampling = 0;
	reg [15:0] audio_max = 0;
	always @(posedge clk)
		if (sampling && audio_out_b > audio_max) audio_max = audio_out_b;

	task run_ce(input integer n);   // n CPU cycles, ce 1-in-12 like 21/1.79 MHz
		integer i;
		begin
			for (i = 0; i < n; i = i + 1) begin
				@(negedge clk); ce = 1;
				@(negedge clk); ce = 0;
				repeat (10) @(posedge clk);
			end
		end
	endtask

	initial begin
		// FPGA registers power up at 0; vrc6sound's dividers have no reset,
		// so model power-on state instead of simulating X propagation.
		force snd_vrc6.snd_vrc6.div0 = 0;
		force snd_vrc6.snd_vrc6.div1 = 0;
		force snd_vrc6.snd_vrc6.div2 = 0;
		force snd_vrc6.snd_vrc6.duty0cnt = 0;
		force snd_vrc6.snd_vrc6.duty1cnt = 0;
		force snd_vrc6.snd_vrc6.duty2cnt = 0;
		force snd_vrc6.snd_vrc6.acc = 0;
		@(posedge clk);
		release snd_vrc6.snd_vrc6.div0;
		release snd_vrc6.snd_vrc6.div1;
		release snd_vrc6.snd_vrc6.div2;
		release snd_vrc6.snd_vrc6.duty0cnt;
		release snd_vrc6.snd_vrc6.duty1cnt;
		release snd_vrc6.snd_vrc6.duty2cnt;
		release snd_vrc6.snd_vrc6.acc;

		// ---------- mapper 23: VRC2/4 banking ----------
		set_mapper(8'd23);
		prg_ain = 16'h8000; #1;
		check22(prg_addr_b, 22'h000000, "VRC4 $8000 default bank 0");
		cpu_write(16'h8000, 8'h05);                 // PRG bank 0 = 5
		prg_ain = 16'h8000; #1;
		check22(prg_addr_b, 22'd5 * 22'h2000, "VRC4 $8000 bank 5");
		cpu_write(16'hB000, 8'h0A);                 // CHR bank 0 low nibble
		cpu_write(16'hB001, 8'h01);                 // CHR bank 0 high bits
		chr_ain = 14'h0000; #1;
		check22(chr_addr_b, {3'b100, 9'd26, 10'd0}, "VRC4 CHR bank 26 at $0000");

		// ---------- mapper 5: MMC5 ----------
		set_mapper(8'd5);
		cpu_write(16'h5100, 8'h03);                 // PRG mode 3 (4x 8kB)
		cpu_write(16'h5115, 8'h82);                 // $A000 window: ROM bank 2
		prg_ain = 16'hA000; #1;
		check22(prg_addr_b, 22'd2 * 22'h2000, "MMC5 $A000 bank 2");
		cpu_write(16'h5104, 8'h02);                 // ExRAM mode 2 (r/w RAM)
		cpu_write(16'h5C42, 8'hAB);                 // ExRAM[$042] = AB
		prg_ain = 16'h5C42;
		repeat (3) @(posedge clk); #1;              // registered ExRAM read
		check8(prg_dout_b, 8'hAB, "MMC5 ExRAM mode2 readback");
		cpu_write(16'h5205, 8'd6);
		cpu_write(16'h5206, 8'd7);
		prg_ain = 16'h5205; #1;
		check8(prg_dout_b, 8'd42, "MMC5 multiplier 6*7 low");
		prg_ain = 16'h5206; #1;
		check8(prg_dout_b, 8'd0, "MMC5 multiplier 6*7 high");

		// ---------- mapper 24: VRC6 audio ----------
		set_mapper(8'd24);
		run_ce(20);
		if (audio_out_b !== 16'h4000) begin
			errors = errors + 1;
			$display("FAIL VRC6 silent baseline: got %h want 4000", audio_out_b);
		end else
			$display("ok   VRC6 silent baseline = %h", audio_out_b);
		cpu_write(16'h9000, 8'h7F);                 // sq1 duty 7, volume 15
		cpu_write(16'h9001, 8'h10);                 // sq1 period low
		cpu_write(16'h9002, 8'h80);                 // sq1 enable, period high 0
		audio_max = 0; sampling = 1;
		run_ce(4000);
		sampling = 0;
		if (audio_max < 16'h4800) begin
			errors = errors + 1;
			$display("FAIL VRC6 audio max %h, want > 4800 (non-zero expansion audio)", audio_max);
		end else
			$display("ok   VRC6 audio max = %h (baseline 4000)", audio_max);

		if (errors == 0) $display("PASS tb_cart_vrc_mmc5");
		else             $display("FAIL tb_cart_vrc_mmc5: %0d errors", errors);
		$finish;
	end
endmodule
