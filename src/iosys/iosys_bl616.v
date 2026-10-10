// IOSys_bl616 - BL616-based IO system
// 
// This manages UART connection to the companion bl616 MCU, accepts ROM loading and other requests,
// and display the text overlay when needed.
// 
// Author: nand2mario, 2/2025

`define MCU_BL616

module iosys_bl616 #(
    parameter FREQ=21_477_000,
    parameter [14:0] COLOR_LOGO=15'b00000_10101_00000,
    parameter [15:0] CORE_ID=1,     // 1: nestang, 2: snestang
    parameter [7:0] LOADING_STATE=0,
    // SAVE-RAM INTERFACE. A generic "save RAM as 512-byte blocks" channel between a
    // core's battery-backed RAM and a file on the MCU's SD card, so saves survive a
    // power-off. Kept core-agnostic (from pcetang's SAVE_IF): the MCU addresses blocks,
    // the core only exposes a RAM port and a "written" strobe.
    //   MCU -> FPGA 0x11 blk[15:0] <512 bytes>   write one block into save RAM (restore)
    //   MCU -> FPGA 0x12 blk[15:0]               request one block back
    //   FPGA -> MCU 0x0A blk[15:0] <512 bytes>   the requested block
    //   FPGA -> MCU 0x0B 0x00                    save RAM written since the last dump
    // The response-type byte on the wire IS the TX state number (see SEND_HEADER), which
    // is why 0x0A/0x0B are the next free states. SAVE_IF=0 elaborates none of this.
    // SAVE_SYNC selects the RAM port flavor: 1 = on-chip dpram, answers in one clock
    // (the smstang/pcetang shape); 0 = SDRAM-backed, one req/ack client of sdram_nes's
    // save channel (sv_req/sv_ack), read data a few clocks after the ack.
    parameter SAVE_IF=0,
    parameter SAVE_AW=13,               // save RAM address width in bytes (13 = 8 KB)
    parameter SAVE_SYNC=1
)
(
    input clk,                      // main logic clock
    // input clk50,                    // 50mhz clock for UART
    input hclk,                     // hdmi clock
    input resetn,

    // OSD display interface
    output overlay,
    input [7:0] overlay_x,          // 0-255
    input [7:0] overlay_y,          // 0-223
    output [14:0] overlay_color,    // BGR5
    input [11:0] joy1,              // DS2/SNES joystick 1: (R L X A RT LT DN UP START SELECT Y B)
    input [11:0] joy2,              // DS2/SNES joystick 2
    output reg [15:0] hid1,         // USB HID joystick 1
    output reg [15:0] hid2,         // USB HID joystick 2

    // ROM loading interface
    output [7:0] rom_loading,   // 0-to-1 loading starts, 1-to-0 loading is finished
    output reg [7:0] rom_do,        // first 64 bytes are snes header + 32 bytes after snes header 
    output reg rom_do_valid,        // strobe for rom_do

    // PCXT management interface
    output reg [15:0] mgmt_address,
    output reg        mgmt_read,
    input      [15:0] mgmt_readdata,
    output reg        mgmt_write,
    output reg [15:0] mgmt_writedata,
    input      [1:0]  fdd_request,      // [1]: write, [0]: read

    // Keyboard interface
    input reg  [7:0] kbd_data,
    output reg       kbd_data_valid,

    // Save-RAM port (SAVE_IF=1 only; tie inputs to 0 and leave outputs open otherwise).
    // Same clock as `clk`. With SAVE_SYNC=1 the core owns the other port of a
    // dual-port RAM; with SAVE_SYNC=0 sv_addr/sv_din/sv_we/sv_req feed sdram_nes's
    // save channel and sv_q/sv_ack come back from it.
    output     [SAVE_AW-1:0] sv_addr,
    output     [7:0]         sv_din,
    output                   sv_we,
    input      [7:0]         sv_q,
    input                    sv_core_we,    // the CORE wrote save RAM this cycle
    output reg               sv_req,        // SAVE_SYNC=0 only
    input                    sv_ack,        // SAVE_SYNC=0 only

    output reg [31:0] core_config,

    // UART interface
    input  uart_rx,
    output uart_tx
);

localparam integer STR_LEN = 73; // number of characters in the config string
localparam [8*STR_LEN-1:0] CONF_STR = "Tangcores;-;O12,OSD key,Right+Select,Select+Start,Select+RB;-;V,v20240101";

// Remove SPI parameters and add UART parameters
localparam CLK_FREQ = FREQ;
localparam BAUD_RATE = 2_000_000;

reg overlay_reg = 1;
assign overlay = overlay_reg;

reg [7:0] rom_loading_reg = LOADING_STATE;
assign rom_loading = rom_loading_reg;

// UART receiver signals
wire [7:0] rx_data;
wire rx_valid;

// UART transmitter signals
reg [7:0] tx_data;
reg tx_valid;
wire tx_ready;

// synchronize uart_rx to clk
reg uart_rx_r = 1, uart_rx_rr = 1;
always @(posedge clk) begin
    uart_rx_r <= uart_rx;
    uart_rx_rr <= uart_rx_r;
end

// Instantiate UART modules
async_receiver #(
    .ClkFrequency(CLK_FREQ),
    .Baud(BAUD_RATE)
) uart_receiver (
    .clk(clk),
    .RxD(uart_rx_rr),
    .RxD_data(rx_data),
    .RxD_data_ready(rx_valid)
);

async_transmitter #(
    .ClkFrequency(CLK_FREQ),
    .Baud(BAUD_RATE)
) uart_transmitter (
    .clk(clk),
    .TxD(uart_tx),
    .TxD_data(tx_data),
    .TxD_start(tx_valid),
    .TxD_busy(tx_busy)
);
assign tx_ready = ~tx_busy;

// Command processing state machine
localparam RECV_IDLE         = 7'b0000001; // waiting for command
localparam RECV_LEN1         = 7'b0000010; // receiving length msb
localparam RECV_LEN2         = 7'b0000100; // receiving length lsb
localparam RECV_CMD          = 7'b0001000; // receiving command
localparam RECV_PARAM        = 7'b0010000; // receiving parameters
localparam RECV_RESPONSE_REQ = 7'b0100000; // post a response request to TX
reg [6:0] recv_state = RECV_IDLE;

// UART command buffer
reg [7:0] cmd_reg;
reg [15:0] len_reg;
reg [31:0] data_reg;
reg [23:0] rom_remain;
reg [15:0] data_cnt;
reg [3:0] kbd_len;

// Add new registers for textdisp interface
reg [7:0] x_wr;
reg [7:0] y_wr;
reg [7:0] char_wr;
reg we;

// Add these registers for cursor management
reg [7:0] cursor_x;
reg [7:0] cursor_y;

reg [7:0] response_type;
reg response_req;
reg response_ack;

// mgmt_* multiplex
reg mgmt_rx;
reg [15:0] mgmt_address_rx;
reg [15:0] mgmt_address_tx;
assign mgmt_address = mgmt_rx ? mgmt_address_rx : mgmt_address_tx;

localparam FDD_READY = 0;
localparam FDD_READ_WAIT = 1;
localparam FDD_DONE_WAIT = 2;

reg [1:0] fdd_state;
reg fdd_read_start, fdd_read_finish, fdd_write_finish;

// save-RAM interface state (SAVE_IF=1)
reg [SAVE_AW-1:0] sv_waddr;         // RX side: restore write address
reg [SAVE_AW-1:0] sv_raddr;         // TX side: dump read address
reg [15:0]        sv_req_blk;       // block the MCU asked for (latched in RX)
reg               sv_rd_req = 0, sv_rd_ack = 0;   // RX->TX toggle handshake
reg               sv_dirty = 0;     // core wrote save RAM since the last dump of block 0
reg               sv_notify = 0;    // a 0x0B notice is owed
reg [9:0]         sv_idx;           // TX byte index within a block frame

reg sv_we_b = 0;                    // dpram write strobe (SAVE_SYNC=1)
reg sv_wr_stb = 0;                  // pulses (SAVE_SYNC=0): RX byte for the engine,
reg sv_rd_stb = 0;                  // read sv_raddr please,
reg sv_data_taken = 0;              // TX consumed the read data
reg [SAVE_AW-1:0] sv_addr_e = 0;    // the engine's port, when SAVE_SYNC=0
reg [7:0]         sv_din_e = 0;     // captured at stb, so a late commit can't grab
reg               sv_we_e = 0;      // the NEXT UART byte's data
reg  [7:0]          sv_din_rx = 0;    // RX-side data register (dpram path)
reg               sv_wr_pend = 0, sv_rd_pend = 0, sv_data_rdy = 0, sv_ack_d = 0;
reg  [1:0]        sv_ack_s = 0;     // 2FF sync of sv_ack (sdram_nes fclk domain)
reg  [4:0]        sv_rd_lat = 0;    // read-data settle countdown

assign sv_addr = SAVE_SYNC ? (sv_we_b ? sv_waddr : sv_raddr) : sv_addr_e;
assign sv_we   = SAVE_SYNC ? sv_we_b : sv_we_e;
assign sv_din  = SAVE_SYNC ? sv_din_rx : sv_din_e;

// ---- save-RAM access engine (SAVE_SYNC=0): one req/ack client of sdram_nes.
// Writes (the restore stream) win over reads (the dump); the MCU never does both
// at once. sdram_nes answers the ack when the byte is on the wire; for a read,
// sv_q follows a few clocks later, far inside one UART byte (2 Mbaud = ~107 clk).
always @(posedge clk) begin
    if (!resetn) begin
        sv_req <= 0;
        sv_ack_s <= 0;
        sv_ack_d <= 0;
        sv_rd_lat <= 0;
        sv_wr_pend <= 0;
        sv_rd_pend <= 0;
        sv_data_rdy <= 0;
        sv_addr_e <= 0;
        sv_din_e <= 0;
        sv_we_e <= 0;
    end else if (SAVE_IF && !SAVE_SYNC) begin
        sv_ack_s <= {sv_ack_s[0], sv_ack};     // sdram_nes toggles ack in fclk domain
        sv_ack_d <= sv_ack_s[1];
        if (sv_wr_stb) begin
            sv_wr_pend <= 1;
            sv_din_e <= sv_din_rx;        // hold this byte until the write commits
        end
        if (sv_rd_stb)  sv_rd_pend <= 1;
        // a read completes at cycle[4] of its frame, a few fclk after the ack;
        // the countdown (≪ one UART byte) keeps TX from sampling a stale sv_q
        if (sv_ack_s[1] != sv_ack_d && !sv_we_e)
            sv_rd_lat <= 5'd24;
        else if (sv_rd_lat != 0) begin
            sv_rd_lat <= sv_rd_lat - 1'd1;
            if (sv_rd_lat == 5'd1) sv_data_rdy <= 1;
        end
        if (sv_data_taken) sv_data_rdy <= 0;
        if (sv_req == sv_ack_s[1]) begin          // bus empty: issue one transaction
            if (sv_wr_pend) begin
                sv_wr_pend <= 0;
                sv_addr_e <= sv_waddr;
                sv_we_e   <= 1;
                sv_req    <= ~sv_req;
            end else if (sv_rd_pend) begin
                sv_rd_pend <= 0;
                sv_addr_e <= sv_raddr;
                sv_we_e   <= 0;
                sv_req    <= ~sv_req;
            end
        end
    end
end
// the engine commits the byte captured at sv_wr_stb, at the address sv_waddr
// held there; the RX side advances it every byte, exactly like the dpram path.

// The TangCore bl616-fpga UART protocol
//
// Since 0.9, we've introduce a data frame to avoid spurious messages:
//
//         0xAA frame_len[15:0] payload_of_frame_len_bytes
//
// Command payloads from BL616 to FPGA:
// 0x01                       get core ID (response type 0x01, see below), frame_len = 1
// 0x02                       get core config string (response type 0x02, see below)
// 0x03 x[31:0]               set core config status
// 0x04 x[7:0] y[7:0]         move overlay text cursor to (x, y)
// 0x05 <string>              display string from cursor (len implied by frame header, =frame_len-1)
// 0x06 loading_state[7:0]    set loading state (0: core running, non-0: loading)
// 0x07 <data>                load data to rom_do (len implied by frame header)
// 0x08 x[7:0]                x[0]: turn overlay on/off
// 0x09 hid1[15:0] hid2[15:0] send USB joystick state to FPGA
// 0x0a <data_sector>         send a sector (512 bytes) of data to floppy data FIFO
// 0x0b addr[15:0] data[15:0] write to disk management interface (mgmt_address and mgmt_writedata)
// 0x0c <scancode>            send PS/2 scancode (len specified by frame header)
// 0x0d <string>              debug printf. core ignores this.
// 0x11 blk[15:0] <512 bytes> write one block into save RAM (SAVE_IF only)
// 0x12 blk[15:0]             request one save-RAM block (SAVE_IF only)
//
// Response payloads from FPGA to BL616:
// 0x01 core_id[7:0]          core ID
// 0x02 <string>              core config string (len specified by frame header)
// 0x03 joy1[15:0] joy2[15:0] every 20ms, send DS2/SNES joypad state to BL616
// 0x04 lba[15:0] <data_512>  write a sector to disk
// 0x05 lba[15:0]             read a sector from disk (followed by command 0x0a)
// 0x0a blk[15:0] <512 bytes> the requested save-RAM block (SAVE_IF only)
// 0x0b 0x00                  save RAM changed by the core since the last dump (SAVE_IF only)

// UART RX: command processing
always @(posedge clk) begin
    if (!resetn) begin
        recv_state <= RECV_IDLE;
        cmd_reg <= 0;
        data_reg <= 0;
        rom_loading_reg <= 0;
        rom_remain <= 0;
        core_config <= 0;
        data_cnt <= 0;
        x_wr <= 0;
        y_wr <= 0;
        char_wr <= 0;
        we <= 0;
        cursor_x <= 0;
        cursor_y <= 0;
        sv_we_b <= 0;
        sv_wr_stb <= 0;
        sv_waddr <= 0;
        sv_din_rx <= 0;
        sv_req_blk <= 0;
        sv_rd_req <= 0;
    end else begin
        rom_do_valid <= 0;
        we <= 0;
        mgmt_write <= 0;
        fdd_read_finish <= 0;
        mgmt_rx <= 0;
        kbd_data_valid <= 0;
        sv_we_b <= 0;
        sv_wr_stb <= 0;

        case (recv_state)

            RECV_IDLE: if (rx_valid && rx_data == 8'hAA) begin
                recv_state <= RECV_LEN1;
            end

            RECV_LEN1: if (rx_valid) begin
                len_reg[15:8] <= rx_data;
                if (rx_data < 8)                      // max frame length 2047
                    recv_state <= RECV_LEN2;
                else
                    recv_state <= RECV_IDLE;
            end

            RECV_LEN2: if (rx_valid) begin
                len_reg[7:0] <= rx_data;
                recv_state <= RECV_CMD;
            end

            RECV_CMD: if (rx_valid) begin
                cmd_reg <= rx_data;
                if (rx_data == 1 || rx_data == 2) 
                    recv_state <= RECV_RESPONSE_REQ;    // request sending core id / config string
                else if (len_reg > 1)
                    recv_state <= RECV_PARAM;
                else
                    recv_state <= RECV_IDLE;
                data_cnt <= 0;
            end
            
            RECV_PARAM: if (rx_valid) begin
                data_reg <= {data_reg[23:0], rx_data};
                data_cnt <= data_cnt + 1;
                // e.g. set_overlay x[7:0], the 1st param byte is the last 
                //      (data_cnt == 0, len_reg == 2)
                if (data_cnt + 2 == len_reg)
                    recv_state <= RECV_IDLE;
                
                case (cmd_reg)
                    3: begin
                        if (data_cnt == 3) begin    // Received 4 bytes
                            core_config <= {data_reg[23:0], rx_data};
                        end
                    end
                    4: case (data_cnt)              // cursor
                        0: cursor_x <= rx_data;
                        1: cursor_y <= rx_data;
                        default: ;
                    endcase
                    5: begin                        // print
                        x_wr <= cursor_x;
                        y_wr <= cursor_y;
                        char_wr <= rx_data;
                        if (cursor_x < 32) begin
                            cursor_x <= cursor_x + 1;
                            we <= 1;
                        end
                    end
                    6: begin
                        rom_loading_reg <= rx_data;
                        recv_state <= RECV_IDLE;    // Single byte command
                    end
                    7: begin
                        rom_do <= rx_data;
                        rom_do_valid <= 1;      // pulse data valid
                    end
                    8: begin
                        overlay_reg <= rx_data[0];
                    end
                    9: begin
                        case (data_cnt)
                            0: hid1[15:8] <= rx_data;
                            1: hid1[7:0] <= rx_data;
                            2: hid2[15:8] <= rx_data;
                            3: hid2[7:0] <= rx_data;
                            default: ;
                        endcase
                    end
                    'ha: begin                      // send read data to disk controller
                        mgmt_rx <= 1;
                        mgmt_address_rx <= 16'hf20f;
                        mgmt_writedata <= rx_data;
                        mgmt_write <= '1;
                        if (data_cnt == 511) 
                            fdd_read_finish <= 1;
                    end
                    'hb: begin                      // write disk controller register
                        mgmt_rx <= 1;
                        case (data_cnt)
                            0: mgmt_address_rx[15:8] <= rx_data;
                            1: mgmt_address_rx[7:0] <= rx_data;
                            2: mgmt_writedata[15:8] <= rx_data;
                            3: begin
                                mgmt_writedata[7:0] <= rx_data;
                                mgmt_write <= '1;
                            end
                            default: ;
                        endcase
                    end
                    'hc: begin                      // send PS/2 scancode to PCXT
                        kbd_data <= rx_data;
                        kbd_data_valid <= 1;
                    end
                    'h11: if (SAVE_IF) begin       // write one save-RAM block
                        // data_cnt 0 is blk[15:8]: unused, SAVE_AW-9 bits of blk suffice
                        if (data_cnt == 1)
                            sv_waddr <= {rx_data, 9'd0};   // blk * 512 (truncated to SAVE_AW)
                        else if (data_cnt >= 2 && data_cnt < 2 + 512) begin
                            // >= 2 matters: byte 0 (blk[15:8]) must NOT fall through to a
                            // write -- it would land at the previous frame's last address.
                            sv_din_rx <= rx_data;
                            if (SAVE_SYNC) begin
                                sv_we_b <= 1;
                                if (data_cnt > 2)
                                    sv_waddr <= sv_waddr + 1'd1;
                            end else begin
                                sv_wr_stb <= 1;                   // hand the byte to the engine
                                if (data_cnt > 2)
                                    sv_waddr <= sv_waddr + 1'd1;
                            end
                        end
                    end
                    'h12: if (SAVE_IF) begin       // request one save-RAM block back
                        if (data_cnt == 0)
                            sv_req_blk[15:8] <= rx_data;
                        else if (data_cnt == 1) begin
                            sv_req_blk[7:0] <= rx_data;
                            sv_rd_req <= ~sv_rd_req;
                        end
                    end
                    default: begin
                        // unknown command: consume all data and return
                    end
                endcase
            end

            // Post the request to TX and go straight back to listening. RX used to
            // wait here until TX had sent the reply, deaf to the MCU meanwhile; with
            // a 519-byte save block on the wire that is ~3 ms, and whatever the MCU
            // sent then (the save task's next 0x12, a HID or core_config frame) was
            // lost. A request that arrives while one is still pending is merged
            // into it: the one reply answers both.
            RECV_RESPONSE_REQ: begin                // 1: core ID, 2: config string
                if ((cmd_reg == 1 || cmd_reg == 2) && response_req == response_ack) begin
                    response_type <= cmd_reg;
                    response_req <= ~response_req;
                end
                recv_state <= RECV_IDLE;
            end
        endcase
        
    end
end

localparam SEND_IDLE = 0;

localparam SEND_CORE_ID = 1;        // doubles as response type in message header
localparam SEND_CONFIG_STRING = 2;
localparam SEND_JOYPAD = 3;
localparam SEND_FDD_WRITE = 4;
localparam SEND_FDD_READ = 5;

localparam SEND_HEADER = 6;
localparam SEND_DONE = 7;

localparam SEND_SAVE_BLK = 10;      // save-RAM block (response type 0x0A on the wire)
localparam SEND_SAVE_DIRTY = 11;    // save-RAM changed notice (0x0B)

reg [3:0] send_state, send_state_next;
reg [$clog2(STR_LEN+1)-1:0] send_idx;
localparam JOY_UPDATE_INTERVAL = 50_000_000 / 50; // 20ms interval for 50Hz
reg [$clog2(JOY_UPDATE_INTERVAL+1)-1:0] joy_timer;
reg [15:0] joy1_reg;
reg [15:0] joy2_reg;
reg [15:0] resp_frame_len;

// UART TX: command responses, joystick updates and FDD requests
always @(posedge clk) begin
    if (!resetn) begin
        joy_timer <= 0;
        send_state <= 0;
        sv_raddr <= 0;
        sv_idx <= 0;
        sv_dirty <= 0;
        sv_notify <= 0;
        sv_rd_ack <= 0;
        sv_rd_stb <= 0;
        sv_data_taken <= 0;
    end else begin
        tx_valid <= 0;
        mgmt_read <= 0;
        fdd_read_start <= 0;
        fdd_write_finish <= 0;
        sv_rd_stb <= 0;
        sv_data_taken <= 0;
        
        // Joypad state transmission logic
        joy_timer <= joy_timer == 0 ? 0 : joy_timer - 1;

        // Save-RAM change tracking. A core write marks the RAM dirty and owes the MCU one
        // 0x0B notice; the MCU then dumps it after the game goes quiet. Dirty is cleared
        // when a dump of block 0 starts, so a write landing mid-dump re-dirties it and
        // earns a fresh notice -- a save can lag, but it can never be silently lost.
        if (SAVE_IF && sv_core_we) begin
            if (!sv_dirty) sv_notify <= 1;
            sv_dirty <= 1;
        end

        // UART transmission state machine
        case (send_state)
            SEND_IDLE: begin
                send_idx <= 0;
                if (joy_timer == 0 && (joy1 != joy1_reg || joy2 != joy2_reg)) begin
                    joy_timer <= JOY_UPDATE_INTERVAL;
                    joy1_reg <= joy1;
                    joy2_reg <= joy2;
                    send_state_next <= SEND_JOYPAD;
                    send_state <= SEND_HEADER;
                    resp_frame_len <= 5;
                end else if (fdd_request[1] && fdd_state == FDD_READY) begin
                    send_state_next <= SEND_FDD_WRITE;
                    send_state <= SEND_HEADER;
                    mgmt_address_tx <= 16'hf200;    // read {drive, sector}
                    resp_frame_len <= 515;
                end else if (fdd_request[0] && fdd_state == FDD_READY) begin
                    send_state_next <= SEND_FDD_READ;
                    send_state <= SEND_HEADER;
                    mgmt_address_tx <= 16'hf200;    // read {drive, sector}
                    resp_frame_len <= 3;
                end else if (response_req != response_ack) begin
                    if (response_type == 2) begin
                        send_state_next <= SEND_CONFIG_STRING;
                        send_state <= SEND_HEADER;
                        resp_frame_len <= STR_LEN + 1;
                    end else if (response_type == 1) begin
                        send_state_next <= SEND_CORE_ID;
                        send_state <= SEND_HEADER;
                        resp_frame_len <= 2;
                    end
                // Save traffic goes last. The MCU asks for the next block as soon as
                // one arrives, so a save request is nearly always pending during a
                // dump; ahead of the core-ID reply it starved the firmware's
                // get_core_id() polls for the whole dump (128-256 blocks of ~2.9 ms
                // on MD/SNES/GBA) whenever a joypad frame let the next 0x12 land first.
                end else if (SAVE_IF && sv_rd_req != sv_rd_ack) begin
                    send_state_next <= SEND_SAVE_BLK;
                    send_state <= SEND_HEADER;
                    resp_frame_len <= 1 + 2 + 512;          // type + blk16 + data
                    sv_raddr <= {sv_req_blk[7:0], 9'd0};    // base of the dump read
                    sv_idx <= 0;
                    if (!SAVE_SYNC)
                        sv_rd_stb <= 1;                     // engine: fetch byte 0
                    if (sv_req_blk == 0 && !sv_core_we)
                        sv_dirty <= 0;                      // dump starting: clean again
                end else if (SAVE_IF && sv_notify) begin
                    send_state_next <= SEND_SAVE_DIRTY;
                    send_state <= SEND_HEADER;
                    resp_frame_len <= 2;                    // type + one pad byte
                end
            end

            SEND_HEADER: begin              // 4 byte header: 0xAA, resp_frame_len[15:0], resp_type[7:0]
                if (tx_ready && ~tx_valid) begin
                    tx_valid <= 1;
                    send_idx <= send_idx + 1;
                    case (send_idx[1:0])
                        0: tx_data <= 8'hAA;
                        1: tx_data <= resp_frame_len[15:8];
                        2: tx_data <= resp_frame_len[7:0];
                        3: begin
                            tx_data <= send_state_next;
                            send_state <= send_state_next;
                            send_idx <= 0;
                        end
                        default: ;
                    endcase
                end
            end

            SEND_CORE_ID: begin
                if (tx_ready && ~tx_valid) begin
                    tx_data <= CORE_ID[7:0];
                    tx_valid <= 1;
                    send_state <= SEND_IDLE;
                    response_ack <= response_req;
                end
            end

            SEND_CONFIG_STRING: begin
                if (tx_ready && ~tx_valid) begin
                    tx_data <= CONF_STR[8*(STR_LEN - send_idx - 1) +: 8];
                    tx_valid <= 1;
                    send_idx <= send_idx + 1;
                    if (send_idx == STR_LEN-1) begin
                        send_state <= SEND_IDLE;
                        response_ack <= response_req;
                    end
                end
            end

            SEND_JOYPAD: begin
                if (tx_ready && ~tx_valid) begin
                    case (send_idx)
                        0: tx_data <= joy1_reg[15:8]; // Joy1 high byte
                        1: tx_data <= joy1_reg[7:0];  // Joy1 low byte
                        2: tx_data <= joy2_reg[15:8]; // Joy2 high byte
                        3: tx_data <= joy2_reg[7:0];  // Joy2 low byte
                        default: ;
                    endcase
                    tx_valid <= 1;
                    send_idx <= send_idx + 1;
                    if (send_idx == 3) begin
                        send_state <= SEND_IDLE;
                    end
                end
            end

            // fdd write. Send {drive, sector} followed by 512 bytes data to bl616
            SEND_FDD_WRITE: begin
                if (tx_ready && ~tx_valid) begin
                    case (send_idx)
                        0: tx_data <= mgmt_readdata[15:8];  // sector number
                        1: begin
                            tx_data <= mgmt_readdata[7:0];  // sector number
                            mgmt_address_tx <= 16'hf20f;    // start reading FIFO data
                        end
                        default: begin 
                            tx_data <= mgmt_readdata[7:0];  // send FIFO data
                            mgmt_read <= '1;                // advance FIFO pointer
                        end
                    endcase
                    tx_valid <= 1;
                    send_idx <= send_idx + 1;
                    if (send_idx == 511+2) begin
                        send_state <= SEND_DONE;
                        fdd_write_finish <= 1;              // notify FDD state machine
                    end
                end
            end

            // FDD read. Just second the sector number. BL616 will send the data later via command 0x0b.
            SEND_FDD_READ: begin
                if (tx_ready && ~tx_valid) begin
                    case (send_idx)
                        0: tx_data <= mgmt_readdata[15:8];
                        1: tx_data <= mgmt_readdata[7:0];
                        default: ;
                    endcase
                    tx_valid <= 1;
                    send_idx <= send_idx + 1;
                    if (send_idx == 1) begin
                        send_state <= SEND_DONE;
                        fdd_read_start <= 1;                // notify FDD state machine
                    end
                end
            end

            // Save-RAM block: blk[15:8], blk[7:0], then 512 bytes from save RAM. With
            // SAVE_SYNC=1 the next byte's read is issued as each one is sent; the UART
            // takes over 100 clocks per byte, so the RAM's one-cycle latency is never on
            // the critical path. With SAVE_SYNC=0 each byte waits on the SDRAM engine's
            // sv_data_rdy, which also completes long before the UART asks again.
            SEND_SAVE_BLK: begin
                if (SAVE_IF && tx_ready && ~tx_valid &&
                        (sv_idx < 2 || (SAVE_SYNC ? 1'b1 : sv_data_rdy))) begin
                    if (sv_idx == 0)      tx_data <= sv_req_blk[15:8];
                    else if (sv_idx == 1) tx_data <= sv_req_blk[7:0];
                    else begin
                        tx_data <= sv_q;
                        sv_raddr <= sv_raddr + 1'd1;      // re-armed at the next dump
                        if (!SAVE_SYNC) begin
                            sv_data_taken <= 1;
                            if (sv_idx != 2 + 511)
                                sv_rd_stb <= 1;           // fetch the next byte
                        end
                    end
                    tx_valid <= 1;
                    sv_idx <= sv_idx + 1'd1;
                    if (sv_idx == 2 + 511) begin
                        send_state <= SEND_IDLE;
                        sv_rd_ack <= sv_rd_req;
                    end
                end
            end

            SEND_SAVE_DIRTY: begin
                if (SAVE_IF && tx_ready && ~tx_valid) begin
                    tx_data <= 8'h00;
                    tx_valid <= 1;
                    sv_notify <= 0;
                    send_state <= SEND_IDLE;
                end
            end

            SEND_DONE: send_state <= SEND_IDLE;     // extra state for fdd_state to transition
        endcase
    end
end

// FDD state machine. UART TX only serves FDD requests when fdd_state == FDD_READY.
reg [3:0] fdd_cnt;
always @(posedge clk) begin
    if (!resetn) begin
        fdd_state <= FDD_READY;
    end else case (fdd_state)
        FDD_READY: begin
            if (fdd_read_start) begin
                fdd_state <= FDD_READ_WAIT;
            end else if (fdd_write_finish) begin
                fdd_state <= FDD_DONE_WAIT;
                fdd_cnt <= 15;
            end
        end
        FDD_READ_WAIT: begin
            if (fdd_read_finish) begin
                fdd_state <= FDD_DONE_WAIT;
                fdd_cnt <= 15;
            end
        end
        FDD_DONE_WAIT: begin            // delay 15 cycles before we serve floppy requests again
            fdd_cnt <= fdd_cnt - 1;
            if (fdd_cnt == 0) begin
                fdd_state <= FDD_READY;
            end
        end
    endcase
end

// text display
`ifndef SIM
wire [31:0] reg_char_di = {8'b0, x_wr, y_wr, char_wr};
wire [3:0] reg_char_we = {4{we}};

textdisp #(.COLOR_LOGO(COLOR_LOGO)) disp (
    .clk(clk), .hclk(hclk), .resetn(resetn),
    .x(overlay_x), .y(overlay_y), .color(overlay_color),
    .reg_char_di(reg_char_di), .reg_char_we(reg_char_we)
);
`endif

endmodule
