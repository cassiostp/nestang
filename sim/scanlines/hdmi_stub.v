// Stand-ins for the Gowin and HDMI parts of a scaler, for simulation: a pixel
// counter with the real module's timing (cx, cy count the frame, and
// the picture is the rgb input seen while cx = x + 1), and a pass-through
// output buffer.
module hdmi #(
    parameter VIDEO_ID_CODE = 4,
    parameter DVI_OUTPUT = 0,
    parameter VIDEO_REFRESH_RATE = 60.0,
    parameter IT_CONTENT = 1,
    parameter AUDIO_RATE = 48000,
    parameter AUDIO_BIT_WIDTH = 16,
    parameter START_X = 0,
    parameter START_Y = 0,
    // Same native-timing interface as the real hdmi (see src/hdmi2/hdmi.sv).
    // The default is the NES native 480p120 width: the prep.sh baselines
    // predate the parameter and must run the same line as the DUT, or the
    // clock-for-clock regress comparisons would drift apart.
    parameter NATIVE_FRAME_WIDTH = 855
) (
    input         clk_pixel_x5,
    input         clk_pixel,
    input         clk_audio,
    input  [23:0] rgb,
    input         reset,
    // 1: standard 480p120 timing; anything else (0, or Z from a baseline that
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
    wire [10:0] line_w = (std_timing === 1'b1) ? 11'd858 : NATIVE_FRAME_WIDTH;
    assign frame_width = line_w;
    assign frame_height = 525;
    assign tmds = 3'b0;
    assign tmds_clock = 1'b0;
    always @(posedge clk_pixel) begin
        cx <= (cx == line_w - 11'd1) ? 11'd0 : cx + 11'd1;
        if (cx == line_w - 11'd1)
            cy <= (cy == 10'd524) ? 10'd0 : cy + 10'd1;
    end
endmodule

module ELVDS_OBUF (input I, output O, output OB);
    assign O = I;
    assign OB = ~I;
endmodule
