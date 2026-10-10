// Behavioral stand-in for the Gowin DPB behind gowin_dpb_menu (the iosys OSD
// text buffer: 2048x8, dual port). Same module name and ports as the Gowin IP
// wrapper so the untouched iosys instantiates it directly.
//
// What it models: port A writes (clk domain, the firmware's characters),
// port B reads (hclk domain, the render pipeline). WRITE_MODE 00 / READ_MODE
// 00 with no read-during-write on either port in this design (port A is
// write-only here, port B read-only), so plain registered behavior matches.
// SYNC reset and the output enables are tied off in iosys; they are accepted
// and ignored. INIT_RAM (font/logo ROM content) is NOT modeled: the array
// starts zeroed. Only the character buffer ($000-$37F) is observable to the
// co-sim (firmware writes it before any snapshot reads it); the pixel
// pipeline is not simulated.
//
// For Verilator the array is `public` (the C++ bridge snapshots OSD text
// with direct reads, no model clocking per cell). iverilog ignores it.
module gowin_dpb_menu (douta, doutb, clka, ocea, cea, reseta, wrea, clkb, oceb, ceb, resetb, wreb, ada, dina, adb, dinb);

output [7:0] douta;
output [7:0] doutb;
input clka;
input ocea;
input cea;
input reseta;
input wrea;
input clkb;
input oceb;
input ceb;
input resetb;
input wreb;
input [10:0] ada;
input [7:0] dina;
input [10:0] adb;
input [7:0] dinb;

reg [7:0] mem [0:2047] /*verilator public*/;

reg [7:0] douta_r = 0, doutb_r = 0;
assign douta = douta_r;
assign doutb = doutb_r;

always @(posedge clka) begin
    if (cea) begin
        if (wrea)
            mem[ada] <= dina;
        douta_r <= mem[ada];
    end
end

always @(posedge clkb) begin
    if (ceb)
        doutb_r <= mem[adb];
end

endmodule
