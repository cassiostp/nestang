module soak_top #(
    parameter FREQ = 21_505_376
)(
    input clk, resetn, uart_rx,
    output uart_tx,
    input [11:0] joy1, joy2,
    input core_we,
    output [12:0] sv_addr,
    output [7:0] sv_din,
    output sv_we, sv_req,
    input [7:0] sv_q,
    input sv_ack,
    output tx_launch, rx_valid,
    output [7:0] tx_byte, rx_byte,
    output [3:0] tx_state,
    output [9:0] sv_idx,
    output [31:0] core_config,
    output overlay
);
iosys_bl616 #(.FREQ(FREQ), .CORE_ID(1), .SAVE_IF(1), .SAVE_AW(13), .SAVE_SYNC(0)) dut (
    .clk(clk), .hclk(clk), .resetn(resetn),
    .uart_rx(uart_rx), .uart_tx(uart_tx),
    .joy1(joy1), .joy2(joy2), .sv_core_we(core_we),
    .sv_addr(sv_addr), .sv_din(sv_din), .sv_we(sv_we), .sv_req(sv_req),
    .sv_q(sv_q), .sv_ack(sv_ack), .core_config(core_config), .overlay(overlay),
    .mgmt_readdata(16'd0), .fdd_request(2'b00), .kbd_data(8'd0),
    .overlay_x(8'd0), .overlay_y(8'd0)
);
assign tx_launch = dut.tx_valid && !dut.tx_busy;
assign tx_byte = dut.tx_data;
assign rx_valid = dut.rx_valid;
assign rx_byte = dut.rx_data;
assign tx_state = dut.send_state;
assign sv_idx = dut.sv_idx;
endmodule
