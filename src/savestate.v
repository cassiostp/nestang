// Save-state engine for nestang (TangCore).
//
// Streams a flat state image between the iosys UART block channel (commands
// 0x18/0x19/0x1A, see iosys_bl616.v) and the NES machine while the machine
// is frozen (ss_freeze gates the clock enables exactly like menu pause).
// No staging copy: bulk sections read/write SDRAM directly through the
// battery-save SDRAM port (owned via ss_active while a transfer runs;
// firmware settles battery saves first, so the port is never contended).
//
// Image layout (512-byte blocks):
//   block 0        header (below)
//   bytes 512..    registers (1024 B, byte bus to NES ss_a/ss_din/ss_we)
//   then           CPU-RAM 2048 B  (SDRAM 0x380000)
//   then           CIRAM   2048 B  (SDRAM 0x300000)
//   then           CARTRAM cart_bytes (SDRAM 0x3C0000, per-game, may be 0)
//   then           CHR-RAM chr_bytes  (SDRAM 0x200000, only if has_chr_ram)
//
// Header (little-endian): 0..3 "TCSS", 4 format=1, 5 core-state-ver=1,
// 6 core_id=1, 7 variant (0 standard, 1 hz120), 8..15 mapper_flags,
// 16..19 total_bytes, 20..23 cart_bytes, 24..27 chr_bytes, 28.. firmware
// fields (ROM size/CRC, payload CRC; zero from the FPGA, patched by the
// firmware into its file copy). On load the core re-checks magic, versions,
// mapper_flags and sizes before any reset is issued, so a rejected state
// leaves the running game untouched.
module savestate #(
    parameter [7:0] VARIANT = 8'd0
) (
    input             clk,
    input             clkref,       // SDRAM slot phase from the top
    input             resetn,
    input      [63:0] mapper_flags,
    input             ss_supported,
    input             ss_point,
    output reg        ss_freeze,
    output reg        ss_reset,
    output reg        ss_loaded,
    output            ss_edge_reset,
    output            ss_active,
    // register byte bus to the NES
    output reg [9:0]  ss_a,
    output reg [7:0]  ss_din,
    output reg        ss_we,
    input      [7:0]  ss_dout,
    // SDRAM read-data outputs: they hold the last fetched byte, which the
    // CPU/PPU may not have consumed yet at capture -- two image bytes
    // (register offsets 0x190/0x191) carry them across a load.
    input      [7:0]  sd_douta,
    input      [7:0]  sd_doutb,
    output reg        sd_ld_we,
    output reg [7:0]  sd_ld_douta,
    output reg [7:0]  sd_ld_doutb,
    // SDRAM save port (sdram_nes sv_* client, muxed in the top)
    output reg [21:0] mem_addr,
    output reg [7:0]  mem_din,
    output reg        mem_we,
    output reg        mem_req,
    input             mem_ack,
    input      [7:0]  mem_q,
    // iosys control (0x18 payload): 1 begin-save, 2 begin-load, 3 end, 4 abort
    input      [2:0]  op,
    input             op_stb,
    output     [127:0] ss_status,
    // iosys image byte channel (mirrors the battery save channel shape)
    input      [19:0] img_raddr,
    input             img_rd_stb,
    input             img_taken,
    input             img_abort,
    output reg        img_rdy,
    output reg [7:0]  img_q,
    input      [19:0] img_waddr,
    input      [7:0]  img_wdin,
    input             img_wr_stb
);

localparam [2:0] OP_SAVE = 3'd1, OP_LOAD = 3'd2, OP_END = 3'd3, OP_ABORT = 3'd4;

// ---- per-game section sizes from mapper_flags ----
wire [7:0] mapper = mapper_flags[7:0];
wire [3:0] f_nv   = mapper_flags[34:31];
wire [3:0] f_pr   = mapper_flags[29:26];
wire [3:0] f_chrr = mapper_flags[38:35];

function [18:0] shift_bytes(input [3:0] n);
    // NES 2.0 shift sizes: 64 << n bytes, 0 = none, capped at the window.
    shift_bytes = (n == 4'd0) ? 19'd0 : (n >= 4'd12) ? 19'd262144 : (19'd64 << n);
endfunction

wire [18:0] sz_nv = shift_bytes(f_nv);
wire [18:0] sz_pr = shift_bytes(f_pr);
wire [18:0] sz_base = (sz_nv > sz_pr) ? sz_nv : sz_pr;

wire mmc3_family = (mapper == 8'd4) || (mapper == 8'd33) || (mapper == 8'd37) ||
    (mapper == 8'd47) || (mapper == 8'd48) || (mapper == 8'd74) || (mapper == 8'd76) ||
    (mapper == 8'd80) || (mapper == 8'd82) || (mapper == 8'd88) || (mapper == 8'd95) ||
    (mapper == 8'd112) || (mapper == 8'd118) || (mapper == 8'd119) || (mapper == 8'd154) ||
    (mapper == 8'd191) || (mapper == 8'd192) || (mapper == 8'd194) || (mapper == 8'd195) ||
    (mapper == 8'd206) || (mapper == 8'd207);
// Mappers that park CHR-RAM / extra VRAM at the top of the CARTRAM window,
// plus any 4-screen cart: save the whole 256 KB window (rare games).
wire cart_full = mapper_flags[16] || (mapper == 8'd77) || (mapper == 8'd119) ||
    (mapper == 8'd74) || (mapper == 8'd191) || (mapper == 8'd192) ||
    (mapper == 8'd194) || (mapper == 8'd195);
wire wram_mapper = mmc3_family || (mapper == 8'd1) || (mapper == 8'd155) ||
    (mapper == 8'd171) || (mapper == 8'd10) ||
    ((mapper == 8'd34) && (mapper_flags[13:11] != 3'd0));

wire [18:0] cart_bytes_c = cart_full ? 19'd262144 :
    (sz_base != 19'd0) ? sz_base : (wram_mapper ? 19'd8192 : 19'd0);
wire [18:0] chr_shifted = shift_bytes(f_chrr);
wire [18:0] chr_bytes_c = !mapper_flags[15] ? 19'd0 :
    (chr_shifted != 19'd0) ? chr_shifted : 19'd8192;
wire [19:0] total_bytes_c = 20'd512 + 20'd1024 + 20'd4096 +
    {1'b0, cart_bytes_c} + {1'b0, chr_bytes_c};

// Latched at begin so a flags change mid-transfer (new ROM load aborts us
// first, but belt and braces) cannot move the section boundaries.
reg [18:0] cart_bytes, chr_bytes;
reg [19:0] total_bytes;
wire [19:0] sec_reg_end  = 20'd1536;                 // 512 hdr + 1024 regs
wire [19:0] sec_cpu_end  = sec_reg_end + 20'd2048;
wire [19:0] sec_ciram_end = sec_cpu_end + 20'd2048;
wire [19:0] sec_cart_end = sec_ciram_end + {1'b0, cart_bytes};

// ---- header byte generation (save direction) ----
function [7:0] hdr_byte(input [8:0] a);
    case (a)
    9'd0: hdr_byte = 8'h54;  // T
    9'd1: hdr_byte = 8'h43;  // C
    9'd2: hdr_byte = 8'h53;  // S
    9'd3: hdr_byte = 8'h53;  // S
    9'd4: hdr_byte = 8'd1;
    9'd5: hdr_byte = 8'd1;
    9'd6: hdr_byte = 8'd1;
    9'd7: hdr_byte = VARIANT;
    9'd8:  hdr_byte = mapper_flags[7:0];
    9'd9:  hdr_byte = mapper_flags[15:8];
    9'd10: hdr_byte = mapper_flags[23:16];
    9'd11: hdr_byte = mapper_flags[31:24];
    9'd12: hdr_byte = mapper_flags[39:32];
    9'd13: hdr_byte = mapper_flags[47:40];
    9'd14: hdr_byte = mapper_flags[55:48];
    9'd15: hdr_byte = mapper_flags[63:56];
    9'd16: hdr_byte = total_bytes[7:0];
    9'd17: hdr_byte = total_bytes[15:8];
    9'd18: hdr_byte = {4'b0, total_bytes[19:16]};
    9'd19: hdr_byte = 8'd0;
    9'd20: hdr_byte = cart_bytes[7:0];
    9'd21: hdr_byte = cart_bytes[15:8];
    9'd22: hdr_byte = {5'b0, cart_bytes[18:16]};
    9'd23: hdr_byte = 8'd0;
    9'd24: hdr_byte = chr_bytes[7:0];
    9'd25: hdr_byte = chr_bytes[15:8];
    9'd26: hdr_byte = {5'b0, chr_bytes[18:16]};
    default: hdr_byte = 8'd0;
    endcase
endfunction

// ---- header capture (load direction) ----
reg        chk_magic, chk_ver, chk_core;
reg [63:0] chk_flags;
reg [19:0] chk_total;
reg [18:0] chk_cart, chk_chr;
reg        hdr_ok, hdr_done;

// ---- control FSM ----
localparam [2:0] S_IDLE = 3'd0, S_WAIT = 3'd1, S_SAVE = 3'd2,
                 S_HDR = 3'd3, S_RESET = 3'd4, S_LOAD = 3'd5, S_SETTLE = 3'd6;
reg [2:0]  state = S_IDLE;
reg        err = 0;
reg        was_load = 0;
reg [6:0]  settle_cnt = 0;
reg [26:0] wdog = 0;        // ~6 s at 21.5 MHz without link activity: abort
reg [25:0] wait_cnt = 0;    // capture-point patience (~3 s), then freeze anyway

assign ss_active = (state != S_IDLE);
// Held through load settle: re-arms the SDRAM controller's request edge
// detectors with the final restored bus state frozen, so the pending
// capture-time fetch completes before resume (see sdram_nes.v).
assign ss_edge_reset = (state == S_SETTLE) && was_load;
wire ready = (state == S_SAVE) || (state == S_LOAD) || (state == S_HDR);
wire [15:0] total_blocks = {5'b0, total_bytes_c[19:9]};  // total is 512-aligned by construction
assign ss_status = {
    {5'b0, state}, VARIANT,
    mapper_flags,
    total_blocks,
    8'd1, 8'd1,
    {5'b0, ss_active, err, ready},
    {7'b0, ss_supported}
};

// ---- SDRAM byte engine (same level handshake as iosys's save engine) ----
reg [1:0]  ack_s = 0;
reg        wr_pend = 0, rd_pend = 0, rd_out = 0, resync = 0;
reg [4:0]  rd_lat = 0;
reg [21:0] pend_addr = 0;
reg [7:0]  pend_din = 0;
reg        pend_we = 0;
// Fast-path (header/register) read completion, 1 clk after the strobe.
reg        fast_rdy = 0;
reg [7:0]  fast_q = 0;
reg        fast_sel = 0;   // 1: fast_q (header/dout), 0: ss_regs readback

// Address translation for a byte in a memory section.
function [21:0] mem_translate(input [19:0] a);
    if (a < sec_cpu_end)       mem_translate = 22'h380000 + (a - sec_reg_end);
    else if (a < sec_ciram_end) mem_translate = 22'h300000 + (a - sec_cpu_end);
    else if (a < sec_cart_end)  mem_translate = 22'h3C0000 + (a - sec_ciram_end);
    else                        mem_translate = 22'h200000 + (a - sec_cart_end);
endfunction

always @(posedge clk) begin
    if (!resetn) begin
        state <= S_IDLE;
        ss_freeze <= 0;
        ss_reset <= 0;
        ss_loaded <= 0;
        ss_we <= 0;
        ss_a <= 0;
        ss_din <= 0;
        err <= 0;
        was_load <= 0;
        hdr_ok <= 0;
        hdr_done <= 0;
        img_rdy <= 0;
        img_q <= 0;
        sd_ld_we <= 0;
        sd_ld_douta <= 0;
        sd_ld_doutb <= 0;
        mem_req <= 0;
        mem_addr <= 0;
        mem_din <= 0;
        mem_we <= 0;
        ack_s <= 0;
        wr_pend <= 0;
        rd_pend <= 0;
        rd_out <= 0;
        resync <= 0;
        rd_lat <= 0;
        fast_rdy <= 0;
        wdog <= 0;
        wait_cnt <= 0;
        settle_cnt <= 0;
        cart_bytes <= 0;
        chr_bytes <= 0;
        total_bytes <= 0;
    end else begin
        ss_we <= 0;
        sd_ld_we <= 0;
        ss_loaded <= 0;
        ack_s <= {ack_s[0], mem_ack};

        // ---------- control ----------
        if (op_stb || img_rd_stb || img_wr_stb || img_taken)
            wdog <= 0;
        else if (state != S_IDLE)
            wdog <= wdog + 1'd1;

        if (op_stb) begin
            case (op)
            OP_SAVE: if (state == S_IDLE) begin
                if (!ss_supported) begin
                    err <= 1;
                end else begin
                    err <= 0;
                    was_load <= 0;
                    cart_bytes <= cart_bytes_c;
                    chr_bytes <= chr_bytes_c;
                    total_bytes <= total_bytes_c;
                    wait_cnt <= 0;
                    state <= S_WAIT;
                end
            end
            OP_LOAD: if (state == S_IDLE) begin
                if (!ss_supported) begin
                    err <= 1;
                end else begin
                    err <= 0;
                    was_load <= 1;
                    hdr_ok <= 0;
                    hdr_done <= 0;
                    chk_magic <= 1;
                    chk_ver <= 0;
                    chk_core <= 0;
                    cart_bytes <= cart_bytes_c;
                    chr_bytes <= chr_bytes_c;
                    total_bytes <= total_bytes_c;
                    ss_freeze <= 1;
                    state <= S_HDR;
                end
            end
            OP_END: if (state == S_SAVE || state == S_LOAD) begin
                settle_cnt <= 7'd64;
                state <= S_SETTLE;
            end
            OP_ABORT: begin
                state <= S_IDLE;
                ss_freeze <= 0;
                ss_reset <= 0;
                img_rdy <= 0;
                fast_rdy <= 0;
                wr_pend <= 0;
                rd_pend <= 0;
                rd_out <= 0;
                mem_we <= 0;
                mem_addr <= 0;
                mem_req <= ~mem_req;   // dummy read: rebuild req/ack parity
                resync <= 1;
            end
            default: ;
            endcase
        end else if (state != S_IDLE && &wdog) begin
            // Link went silent mid-transfer: unfreeze rather than wedge.
            state <= S_IDLE;
            ss_freeze <= 0;
            ss_reset <= 0;
            img_rdy <= 0;
            fast_rdy <= 0;
            wr_pend <= 0;
            rd_pend <= 0;
            rd_out <= 0;
            mem_we <= 0;
            mem_addr <= 0;
            mem_req <= ~mem_req;
            resync <= 1;
            err <= 1;
        end

        case (state)
        S_WAIT: begin
            wait_cnt <= wait_cnt + 1'd1;
            if (ss_point || &wait_cnt) begin
                ss_freeze <= 1;
                state <= S_SAVE;
            end
        end
        S_HDR: begin
            if (hdr_done) begin
                hdr_done <= 0;
                if (hdr_ok) begin
                    settle_cnt <= 7'd32;
                    ss_reset <= 1;
                    state <= S_RESET;
                end else begin
                    err <= 1;   // stay frozen in S_HDR; firmware aborts
                end
            end
        end
        S_RESET: begin
            if (settle_cnt == 7'd16)
                ss_reset <= 0;
            if (settle_cnt == 7'd0)
                state <= S_LOAD;
            else
                settle_cnt <= settle_cnt - 1'd1;
        end
        S_SETTLE: begin
            // Unfreeze on a fixed clkref phase (both after a save and after
            // a load): the SDRAM controller's slot timing is locked to
            // clkref, the NES dividers are restored, so resuming at a
            // canonical parity makes the loaded run's memory timing match
            // the saved run's post-save timing cycle for cycle.
            if (settle_cnt == 7'd0 && clkref == 1'b0) begin
                ss_freeze <= 0;
                if (was_load) ss_loaded <= 1;
                state <= S_IDLE;
            end else if (settle_cnt != 7'd0)
                settle_cnt <= settle_cnt - 1'd1;
        end
        default: ;
        endcase

        // ---------- image writes (load direction) ----------
        if (img_wr_stb && (state == S_HDR || state == S_LOAD)) begin
            if (img_waddr < 20'd512) begin
                if (state == S_HDR) begin
                    case (img_waddr[8:0])
                    9'd0: if (img_wdin != 8'h54) chk_magic <= 0;
                    9'd1: if (img_wdin != 8'h43) chk_magic <= 0;
                    9'd2: if (img_wdin != 8'h53) chk_magic <= 0;
                    9'd3: if (img_wdin != 8'h53) chk_magic <= 0;
                    9'd4: chk_ver <= (img_wdin == 8'd1);
                    9'd5: chk_core <= (img_wdin == 8'd1);
                    9'd6: if (img_wdin != 8'd1) chk_core <= 0;
                    9'd8:  chk_flags[7:0] <= img_wdin;
                    9'd9:  chk_flags[15:8] <= img_wdin;
                    9'd10: chk_flags[23:16] <= img_wdin;
                    9'd11: chk_flags[31:24] <= img_wdin;
                    9'd12: chk_flags[39:32] <= img_wdin;
                    9'd13: chk_flags[47:40] <= img_wdin;
                    9'd14: chk_flags[55:48] <= img_wdin;
                    9'd15: chk_flags[63:56] <= img_wdin;
                    9'd16: chk_total[7:0] <= img_wdin;
                    9'd17: chk_total[15:8] <= img_wdin;
                    9'd18: chk_total[19:16] <= img_wdin[3:0];
                    9'd20: chk_cart[7:0] <= img_wdin;
                    9'd21: chk_cart[15:8] <= img_wdin;
                    9'd22: chk_cart[18:16] <= img_wdin[2:0];
                    9'd24: chk_chr[7:0] <= img_wdin;
                    9'd25: chk_chr[15:8] <= img_wdin;
                    9'd26: chk_chr[18:16] <= img_wdin[2:0];
                    default: ;
                    endcase
                    if (img_waddr == 20'd511) begin
                        hdr_done <= 1;
                        hdr_ok <= chk_magic && chk_ver && chk_core &&
                            (chk_flags == mapper_flags) &&
                            (chk_total == total_bytes) &&
                            (chk_cart == cart_bytes) && (chk_chr == chr_bytes);
                    end
                end
            end else if (state == S_LOAD) begin
                if (img_waddr == 20'd512 + 20'h190 || img_waddr == 20'd512 + 20'h191) begin
                    if (img_waddr[0]) sd_ld_doutb <= img_wdin;
                    else              sd_ld_douta <= img_wdin;
                    sd_ld_we <= 1;
                end else if (img_waddr < sec_reg_end) begin
                    ss_a <= (img_waddr - 20'd512);
                    ss_din <= img_wdin;
                    ss_we <= 1;
                end else begin
                    wr_pend <= 1;
                    pend_addr <= mem_translate(img_waddr);
                    pend_din <= img_wdin;
                    pend_we <= 1;
                end
            end
        end

        // ---------- image reads (save direction) ----------
        if (img_abort) begin
            img_rdy <= 0;
            fast_rdy <= 0;
            rd_pend <= 0;
            rd_out <= 0;
            mem_we <= 0;
            mem_addr <= 0;
            resync <= 1;
            mem_req <= ~mem_req;
        end else begin
            if (img_rd_stb && state == S_SAVE) begin
                if (img_raddr < 20'd512) begin
                    fast_q <= hdr_byte(img_raddr[8:0]);
                    fast_rdy <= 1;
                    fast_sel <= 1;
                end else if (img_raddr == 20'd512 + 20'h190 || img_raddr == 20'd512 + 20'h191) begin
                    fast_q <= img_raddr[0] ? sd_doutb : sd_douta;
                    fast_rdy <= 1;
                    fast_sel <= 1;
                end else if (img_raddr < sec_reg_end) begin
                    ss_a <= (img_raddr - 20'd512);
                    fast_rdy <= 1;      // ss_dout valid combinationally next clk
                    fast_sel <= 0;
                end else begin
                    rd_pend <= 1;
                    pend_addr <= mem_translate(img_raddr);
                    pend_we <= 0;
                end
            end
            if (fast_rdy && !img_taken) begin
                img_q <= fast_sel ? fast_q : ss_dout;
                img_rdy <= 1;
                fast_rdy <= 0;
            end
            // NB: taken must not clear fast_rdy -- iosys pulses taken and
            // the next rd_stb in the same cycle.
            if (img_taken) begin
                img_rdy <= 0;
                rd_out <= 0;
            end
        end

        // ---------- SDRAM engine ----------
        if (resync && mem_req == ack_s[1])
            resync <= 0;
        if (rd_out && mem_req == ack_s[1]) begin
            if (rd_lat != 5'd0)
                rd_lat <= rd_lat - 1'd1;
            else if (!img_taken) begin
                img_q <= mem_q;
                img_rdy <= 1;
            end
        end
        if (!resync && mem_req == ack_s[1] && !img_abort && !(op_stb && op == OP_ABORT) && !(state != S_IDLE && &wdog && !op_stb)) begin
            if (wr_pend) begin
                wr_pend <= 0;
                mem_addr <= pend_addr;
                mem_din <= pend_din;
                mem_we <= 1;
                mem_req <= ~mem_req;
            end else if (rd_pend) begin
                rd_pend <= 0;
                mem_addr <= pend_addr;
                mem_we <= 0;
                rd_out <= 1;
                rd_lat <= 5'd24;
                mem_req <= ~mem_req;
            end
        end
    end
end

endmodule
