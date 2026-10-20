// cosim_top: the NES co-simulation DUT. A small top around the REAL MosplusTang
// interface logic -- iosys_bl616 (UART protocol, OSD text, save channel) and
// sdram_nes (SDRAM controller incl. the battery-save client) -- plus a
// behavioral SDRAM chip, NES-like CPU/PPU traffic and test hooks. No game,
// no video, no audio: this exercises firmware<->core interactions (pad
// frames, combos, save dumps/restores, reset, MODE, core_config) without
// hardware.
//
// CYCLES AND CLOCKS
//   clk/fclk/hclk/resetn come from the C++ bridge. fclk must be exactly 3x
//   clk (sdram_nes's 6-cycle frame resyncs on every clkref posedge, and
//   clkref toggles on clk here, exactly as nestang_top drives it). hclk is
//   tied to clk by the bridge: it only feeds textdisp's render pipeline,
//   whose pixels nobody observes (OSD text is snapshotted straight out of
//   the DPB array, see below).
//   One sim tick (firmware sim_time, 1/21.492MHz) is one clk period.
//
// PROGRAMMING MODEL
//   The generated iosys_bl616_cosim answers core-ID replies with the
//   cosim_core_id input (see Makefile: the ONLY difference from the real
//   iosys_bl616.v, made by mechanical sed at build time and verified by
//   diff). Programming a bitstream = the bridge sets cosim_core_id and
//   pulses resetn, like hardware loading fresh logic. SDRAM contents are
//   RETAINED across reset (external chip), matching hardware.
//   silence=1 (MODE blackout) forces both UART lines idle; the bridge ends
//   it with a reset pulse and cosim_core_id=0 (flash bitstream), after which
//   the firmware reboots.
//
// GAME/TRAFFIC MODEL
//   The CPU (B) and PPU (A) ports get pulsed NES-like traffic (LFSR-driven,
//   deterministic): PPU reads every 8 clk, CPU accesses every 12 clk. Any
//   CPU write into the WRAM window [0x3C0000, 0x3C1FFF] pulses sv_core_we,
//   exactly what nes.v's save_written does for real CPU writes -- iosys
//   dirties the save and owes the MCU a 0x0B notice.
//   churn_en: the "game" continuously scribbles WRAM (combo-during-dump).
//   poke_valid/poke_off/poke_data/poke_ack: single game-path WRAM writes for
//   wram-write/wram-burst (and poke-save). Poke wins over churn and normal
//   CPU traffic for its slot.
//   The save channel has the lowest SDRAM priority (real arbitration), so
//   dumps genuinely contend with game traffic.
//
// OBSERVABILITY (all real unless noted)
//   core_config/video_config/overlay: straight out of iosys (expect-config-bit
//   reads the real register). rom_bytes: ROM payload bytes consumed (firmware streams
//   the ROM; no loader parses it here). sdram_busy: controller init.
//   OSD text / save RAM: read by the C++ bridge DIRECTLY out of the
//   behavioral arrays (gowin_dpb_menu.mem, sdram_chip.mem, both
//   `verilator public`), no model clocking per cell. The char buffer lives
//   at DPB $000-$37F = {1'b0, y[4:0], x[4:0]} (32x28).
module cosim_top (
    input wire clk,
    input wire fclk,
    input wire hclk,
    input wire resetn,

    input wire [11:0] joy1,
    input wire [11:0] joy2,

    input wire uart_rx,
    output wire uart_tx,
    input wire silence,
    input wire [15:0] cosim_core_id,

    output wire [31:0] core_config,
    output wire [31:0] video_config,
    output wire overlay,
    output wire sdram_busy,
    output reg [31:0] rom_bytes,
    // TX-pending for the bridge's idle jump: a reply owed or a frame on the
    // wire. Hierarchical into iosys (cosim-owned top; the DUT itself is
    // untouched): send_state covers every TX frame, response_* the core-ID /
    // config-string handoff (RX posts, TX picks up a tick or two later), and
    // sv_* the save-block / dirty-notice path. Without this the bridge would
    // jump over the idle gap between a request and its reply, skipping the
    // reply unsampled. (A joypad frame due on its 20 ms timer is NOT
    // included: delaying it by a jump is harmless, the firmware polls.)
    output wire tx_pending,
    input wire poke_valid,
    input wire [12:0] poke_off,
    input wire [7:0] poke_data,
    output reg poke_ack,
    input wire churn_en
);

import configPackage::*;

reg clkref = 0;
always @(posedge clk) clkref <= ~clkref;

// ---- UART gating (MODE blackout) ----
wire uart_rx_iosys = silence ? 1'b1 : uart_rx;
wire uart_tx_iosys;
assign uart_tx = silence ? 1'b1 : uart_tx_iosys;

// ---- save channel (iosys <-> sdram_nes), as nestang_top wires it ----
wire [12:0] sv_addr;
wire [7:0] sv_din, sv_q;
wire sv_we, sv_req, sv_ack;
reg sv_core_we = 0;

// ---- ROM sink: count what the firmware streams (no loader here) ----
wire [7:0] rom_loading_unused;
wire [7:0] rom_do;
wire rom_do_valid;
always @(posedge clk) begin
    if (!resetn)
        rom_bytes <= 0;
    else if (rom_do_valid)
        rom_bytes <= rom_bytes + 1;
end

assign tx_pending = (sys.send_state != 4'd0) || (sys.response_req != sys.response_ack) ||
                    (sys.sv_rd_req != sys.sv_rd_ack) || sys.sv_notify ||
                    (sys.ss_rd_req != sys.ss_rd_ack) || (sys.ss_st_req != sys.ss_st_ack);

// ---- save-state engine (real src/savestate.v) over a pattern register file ----
// The NES registers it snapshots do not exist here; a 1 KB RAM stands in
// for them (pattern-filled on programming, overwritten by loads), while
// the bulk sections go through the real SDRAM save port exactly as on
// hardware. mapper_flags describes an MMC1 battery game with 8 KB
// CHR RAM, so the image is 22016 bytes, like the firmware host fake.
wire [9:0] ss_a;
wire [7:0] ss_din_engine, ss_dout_regs;
wire ss_we_engine;
wire ss_freeze, ss_reset_unused, ss_loaded, ss_active, ss_edge_reset;
wire ss_sd_ld_we;
wire [7:0] ss_sd_ld_douta, ss_sd_ld_doutb;
wire [21:0] ss_mem_addr;
wire [7:0] ss_mem_din;
wire ss_mem_we, ss_mem_req;
wire [2:0] ss_op;
wire ss_op_stb;
wire [127:0] ss_status;
wire [19:0] ss_img_raddr, ss_img_waddr;
wire ss_img_rd_stb, ss_img_taken, ss_img_abort, ss_img_rdy, ss_img_wr_stb;
wire [7:0] ss_img_q, ss_img_wdin;

reg [7:0] ss_regs[1024];
integer ss_i;
always @(posedge clk) begin
    if (!resetn) begin
        for (ss_i = 0; ss_i < 1024; ss_i = ss_i + 1)
            ss_regs[ss_i] <= (ss_i * 31 + 7) % 256;
    end else if (ss_we_engine) begin
        ss_regs[ss_a] <= ss_din_engine;
    end
end
assign ss_dout_regs = ss_regs[ss_a];

savestate ss_engine (
    .clk(clk), .clkref(clkref), .resetn(resetn),
    .mapper_flags(64'h0000_0038_0000_8401),   // mapper 1, battery, CHR RAM 8K
    .ss_supported(1'b1), .ss_point(1'b1),
    .ss_freeze(ss_freeze), .ss_reset(ss_reset_unused), .ss_loaded(ss_loaded),
    .ss_edge_reset(ss_edge_reset),
    .ss_active(ss_active),
    .ss_a(ss_a), .ss_din(ss_din_engine), .ss_we(ss_we_engine), .ss_dout(ss_dout_regs),
    .sd_douta(doutA), .sd_doutb(doutB),
    .sd_ld_we(ss_sd_ld_we), .sd_ld_douta(ss_sd_ld_douta), .sd_ld_doutb(ss_sd_ld_doutb),
    .mem_addr(ss_mem_addr), .mem_din(ss_mem_din), .mem_we(ss_mem_we),
    .mem_req(ss_mem_req), .mem_ack(sv_ack), .mem_q(sv_q),
    .op(ss_op), .op_stb(ss_op_stb), .ss_status(ss_status),
    .img_raddr(ss_img_raddr), .img_rd_stb(ss_img_rd_stb),
    .img_taken(ss_img_taken), .img_abort(ss_img_abort),
    .img_rdy(ss_img_rdy), .img_q(ss_img_q),
    .img_waddr(ss_img_waddr), .img_wdin(ss_img_wdin), .img_wr_stb(ss_img_wr_stb)
);

iosys_bl616_cosim #(
    .FREQ(21_492_000),
    .SAVE_IF(1),
    .SAVE_AW(13),
    .SAVE_SYNC(0),
    .SS_IF(1)
) sys (
    .clk(clk),
    .hclk(hclk),
    .resetn(resetn),
    .cosim_core_id(cosim_core_id),

    .overlay(overlay),
    .overlay_x(8'h00),
    .overlay_y(8'h00),
    .overlay_color(),
    .joy1(joy1),
    .joy2(joy2),
    .hid1(),
    .hid2(),

    .rom_loading(rom_loading_unused),
    .rom_do(rom_do),
    .rom_do_valid(rom_do_valid),

    .mgmt_address(),
    .mgmt_read(),
    .mgmt_readdata(16'h0),
    .mgmt_write(),
    .mgmt_writedata(),
    .fdd_request(2'b00),

    .kbd_data(8'h0),
    .kbd_data_valid(),

    .sv_addr(sv_addr),
    .sv_din(sv_din),
    .sv_we(sv_we),
    .sv_q(sv_q),
    .sv_core_we(sv_core_we | ss_loaded),
    .sv_req(sv_req),
    .sv_ack(sv_ack),

    .ss_op(ss_op), .ss_op_stb(ss_op_stb), .ss_status(ss_status),
    .ss_img_raddr(ss_img_raddr), .ss_img_rd_stb(ss_img_rd_stb),
    .ss_img_taken(ss_img_taken), .ss_img_abort(ss_img_abort),
    .ss_img_rdy(ss_img_rdy), .ss_img_q(ss_img_q),
    .ss_img_waddr(ss_img_waddr), .ss_img_wdin(ss_img_wdin), .ss_img_wr_stb(ss_img_wr_stb),

    .core_config(core_config),
    .video_config(video_config),
    .uart_rx(uart_rx_iosys),
    .uart_tx(uart_tx_iosys)
);

// ---- SDRAM: real controller + behavioral chip, as nestang_top ----
wire [SDRAM_ROW_WIDTH-1:0] sdram_a;
wire [1:0] sdram_ba;
wire [SDRAM_DATA_WIDTH/8-1:0] sdram_dqm;
wire sdram_ncs, sdram_nwe, sdram_nras, sdram_ncas, sdram_cke;
wire [SDRAM_DATA_WIDTH-1:0] sdram_dq;

reg [21:0] addrA = 0, addrB = 0;
reg oeA = 0, oeB = 0, weB = 0;
reg [7:0] dinB = 0;
wire [7:0] doutA, doutB;

sdram_nes sdram (
    .SDRAM_DQ(sdram_dq),
    .SDRAM_A(sdram_a),
    .SDRAM_BA(sdram_ba),
    .SDRAM_DQM(sdram_dqm),
    .SDRAM_nCS(sdram_ncs),
    .SDRAM_nWE(sdram_nwe),
    .SDRAM_nRAS(sdram_nras),
    .SDRAM_nCAS(sdram_ncas),
    .SDRAM_CKE(sdram_cke),
    .clk(fclk),
    .clkref(clkref),
    .resetn(resetn),
    .busy(sdram_busy),
    .addrA(addrA),
    .weA(1'b0),
    .dinA(8'h0),
    .oeA(oeA),
    .doutA(doutA),
    .addrB(addrB),
    .weB(weB),
    .dinB(dinB),
    .oeB(oeB),
    .doutB(doutB),
    .rv_addr(20'h0),
    .rv_din(16'h0),
    .rv_ds(2'b00),
    .rv_dout(),
    .rv_req(1'b0),
    .rv_req_ack(),
    .rv_we(1'b0),
    .sv_addr(ss_active ? ss_mem_addr : {9'b11_1100_000, sv_addr}),
    .sv_din(ss_active ? ss_mem_din : sv_din),
    .sv_we(ss_active ? ss_mem_we : sv_we),
    .sv_req(ss_active ? ss_mem_req : sv_req),
    .sv_ack(sv_ack),
    .sv_dout(sv_q),
    .ss_edge_reset(ss_edge_reset), .ss_ld_we(ss_sd_ld_we),
    .ss_ld_douta(ss_sd_ld_douta), .ss_ld_doutb(ss_sd_ld_doutb)
);

sdram_chip chip (
    .fclk(fclk),
    .A(sdram_a),
    .BA(sdram_ba),
    .DQM(sdram_dqm),
    .nCS(sdram_ncs),
    .nWE(sdram_nwe),
    .nRAS(sdram_nras),
    .nCAS(sdram_ncas),
    .SDRAM_DQ(sdram_dq)
);

// ---- NES-like CPU/PPU traffic + game WRAM writes (clk domain) ----
// Deterministic 16-bit LFSR (x^16+x^14+x^13+x^11+1), never zero.
reg [15:0] lfsr = 16'hACE1;
function [15:0] lfsr_next(input [15:0] s);
    lfsr_next = {s[14:0], s[15] ^ s[13] ^ s[12] ^ s[10]};
endfunction

localparam [21:0] WRAM_BASE = 22'h3C0000;
reg [15:0] tc = 0;
reg poke_busy = 0;
reg [15:0] churn_div = 0;
reg [1:0] poke_hold = 0;

always @(posedge clk) begin
    if (!resetn) begin
        addrA <= 0;
        addrB <= 0;
        oeA <= 0;
        oeB <= 0;
        weB <= 0;
        dinB <= 0;
        sv_core_we <= 0;
        poke_ack <= 0;
        poke_busy <= 0;
        poke_hold <= 0;
        tc <= 0;
        churn_div <= 0;
        lfsr <= 16'hACE1;
    end else if (!ss_freeze) begin     // the "game" halts for savestates, as on hardware
        tc <= tc + 1;
        lfsr <= lfsr_next(lfsr);
        sv_core_we <= 0;
        // poke_ack is level (not a pulse): it stays up from accept until the
        // bridge releases poke_valid, so a batch-granularity sampler cannot
        // miss it between evaluations.
        if (!poke_valid)
            poke_ack <= 0;

        // Port pulses are held several clk (TB-proven): sdram_nes latches
        // each request at its 6-fclk frame start (cycle[0], once per 2 clk),
        // so a 1-clk pulse could fall between frames and be lost. The edge
        // detectors (reqA/reqB) still see one access per pulse.
        if (tc % 8 == 0) begin
            oeA <= 1;
            addrA <= 22'h200000 + ({6'h0, lfsr} & 22'h1FFF);
        end
        if (tc % 8 == 4)
            oeA <= 0;

        if (poke_valid && !poke_busy) begin
            // Test hook: one game-path WRAM write (dirties the save).
            poke_busy <= 1;
            poke_hold <= 3;
            addrB <= WRAM_BASE + {9'h0, poke_off};
            dinB <= poke_data;
            weB <= 1;
            sv_core_we <= 1;
            poke_ack <= 1;
        end else if (!poke_valid) begin
            poke_busy <= 0;
            // CPU: one access every 12 clk, held 6.
            if (tc % 12 == 0) begin
                if (churn_en && (tc % 48 == 0)) begin
                    // The game scribbles WRAM as work RAM (combo-during-dump).
                    churn_div <= churn_div + 1;
                    addrB <= WRAM_BASE + {9'h0, (lfsr[12:0] ^ churn_div[12:0])};
                    dinB <= lfsr[7:0] ^ churn_div[7:0];
                    weB <= 1;
                    sv_core_we <= 1;
                end else begin
                    oeB <= 1;
                    addrB <= 22'h000000 + ({6'h0, lfsr} & 22'h7FFF);
                end
            end
            if (tc % 12 == 6) begin
                oeB <= 0;
                weB <= 0;
            end
        end
        // Poke holds its write past the accept cycle so the frame start
        // catches it even if the bridge releases poke_valid at once.
        if (poke_hold != 0) begin
            poke_hold <= poke_hold - 1'd1;
            weB <= 1;
        end
    end
end

endmodule
