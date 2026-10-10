// Stand-ins for the Gowin and HDMI parts of a scaler, for simulation: a pixel
// counter with the real module's timing (cx, cy count the 1650x750 frame, and
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
    parameter START_Y = 0
) (
    input         clk_pixel_x5,
    input         clk_pixel,
    input         clk_audio,
    input  [23:0] rgb,
    input         reset,
    input  [15:0] audio_sample_word [1:0],
    output [2:0]  tmds,
    output        tmds_clock,
    output reg [10:0] cx = START_X,
    output reg [9:0]  cy = START_Y,
    output [10:0] frame_width,
    output [9:0]  frame_height
);
    assign frame_width = 1650;
    assign frame_height = 750;
    assign tmds = 3'b0;
    assign tmds_clock = 1'b0;
    always @(posedge clk_pixel) begin
        cx <= (cx == 11'd1649) ? 11'd0 : cx + 11'd1;
        if (cx == 11'd1649)
            cy <= (cy == 10'd749) ? 10'd0 : cy + 10'd1;
    end
endmodule

module ELVDS_OBUF (input I, output O, output OB);
    assign O = I;
    assign OB = ~I;
endmodule
