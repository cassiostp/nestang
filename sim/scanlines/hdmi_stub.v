// Stand-ins for the Gowin and HDMI parts of a scaler, for simulation: a pixel
// counter with the real module's timing (cx, cy count the frame, and
// the picture is the rgb input seen while cx = x + 1), and a pass-through
// output buffer. With HZ120 the stub counts the 480p120 frame (858 x 525,
// native 855); otherwise the 720p frame (1650 x 750, native 1647).
`include "variant.vh"

module hdmi #(
    parameter VIDEO_ID_CODE = 4,
    parameter DVI_OUTPUT = 0,
`ifdef HZ120
    parameter VIDEO_REFRESH_RATE = 120.0,
`else
    parameter VIDEO_REFRESH_RATE = 60.0,
`endif
    parameter IT_CONTENT = 1,
    parameter AUDIO_RATE = 48000,
    parameter AUDIO_BIT_WIDTH = 16,
    parameter START_X = 0,
    parameter START_Y = 0,
    // Same native-timing interface as the real hdmi (see src/hdmi2/hdmi.sv).
    // The default is the NES native width, not the real module's 1650: the
    // prep.sh baselines predate the parameter and must run the same line as
    // the DUT, or the clock-for-clock regress comparisons would drift apart.
`ifdef HZ120
    parameter NATIVE_FRAME_WIDTH = 855
`else
    parameter NATIVE_FRAME_WIDTH = 1647
`endif
) (
    input         clk_pixel_x5,
    input         clk_pixel,
    input         clk_audio,
    input  [23:0] rgb,
    input         reset,
    // 1: standard timing; anything else (0, or Z from a baseline that
    // predates the port): native width. Case-equality keeps Z on native.
    input         std_timing,
    input  [15:0] audio_sample_word [1:0],
    output [2:0]  tmds,
    output        tmds_clock,
    output reg [10:0] cx = START_X,
    output reg [9:0]  cy = START_Y,
    output [10:0] frame_width,
    output [9:0]  frame_height
);
`ifdef HZ120
    wire [10:0] line_w = (std_timing === 1'b1) ? 11'd858 : NATIVE_FRAME_WIDTH;
    assign frame_width = line_w;
    assign frame_height = 525;
`else
    wire [10:0] line_w = (std_timing === 1'b1) ? 11'd1650 : NATIVE_FRAME_WIDTH;
    assign frame_width = line_w;
    assign frame_height = 750;
`endif
    assign tmds = 3'b0;
    assign tmds_clock = 1'b0;
    always @(posedge clk_pixel) begin
        cx <= (cx == line_w - 11'd1) ? 11'd0 : cx + 11'd1;
        if (cx == line_w - 11'd1)
`ifdef HZ120
            cy <= (cy == 10'd524) ? 10'd0 : cy + 10'd1;
`else
            cy <= (cy == 10'd749) ? 10'd0 : cy + 10'd1;
`endif
    end
endmodule

module ELVDS_OBUF (input I, output O, output OB);
    assign O = I;
    assign OB = ~I;
endmodule
