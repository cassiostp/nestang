// Sim-only replacement for src/game_data.v: feeds an iNES file to the
// GameLoader like iosys would (one byte every 4 clocks, `downloading` high
// throughout). The file comes from the command line, so the testbench is not
// tied to the one hex file game_data.v hard-codes:
//   +rom=<hex file, one byte per line>  +size=<bytes>
module GameData (
    input clk,
    input reset,
    output reg downloading,
    output reg [7:0] odata,
    output reg odata_clk
);

localparam MAX = 262144 + 16;
reg [7:0] INES[0:MAX-1];
integer size = 0;
reg [255:0] path;
reg [1:0] state = 0;
reg [18:0] addr = 0;
reg [1:0] cnt;

initial begin
    if (!$value$plusargs("size=%d", size)) size = 0;
    if ($value$plusargs("rom=%s", path)) $readmemh(path, INES);
end

always @(posedge clk) begin
    if (reset) begin
        state <= 0;
        addr <= 0;
        odata_clk <= 0;
    end else if (state == 0) begin
        state <= 1;
        downloading <= 1;
        cnt <= 0;
    end else if (state == 1) begin
        cnt <= cnt + 1;
        odata_clk <= 0;
        case (cnt)
        2'd0: begin
            odata <= INES[addr];
            odata_clk <= 1;
        end
        2'd3: begin
            if (addr == size - 1) begin
                state <= 2;
                downloading <= 0;
            end
            addr <= addr + 1;
        end
        default: ;
        endcase
    end
end

endmodule
