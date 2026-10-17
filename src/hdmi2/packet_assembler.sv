// Implementation of HDMI packet ECC calculation.
// By Sameer Puri https://github.com/sameer

module packet_assembler (
    input logic clk_pixel,
    input logic reset,
    input logic data_island_period,
    input logic [23:0] header, // See Table 5-8 Packet Types
    input logic [55:0] sub [3:0],
    output logic [8:0] packet_data, // See Figure 5-4 Data Island Packet and ECC Structure
    output logic [4:0] counter = 5'd0
);

// 32 pixel wrap-around counter. See Section 5.2.3.4 for further information.
always_ff @(posedge clk_pixel)
begin
    if (reset)
        counter <= 5'd0;
    else if (data_island_period)
        counter <= counter + 5'd1;
end

// The packet bits come out of shift registers loaded with header/sub while
// counter is 0 (the picker holds them still for the whole packet, and the
// counter-0 bits are taken from the inputs directly). The original design
// selected every bit with sub[i][2*counter +: 2]: at a 148.5 MHz pixel
// clock the path picker -> 56-to-1 mux -> ECC -> parity register was the
// critical path of the pixel domain. The output bits are unchanged.
logic [55:0] sub_sr [3:0] = '{56'd0, 56'd0, 56'd0, 56'd0};
logic [23:0] header_sr = 24'd0;
always_ff @(posedge clk_pixel)
begin
    if (data_island_period)
    begin
        if (counter == 5'd0)
        begin
            for (int i = 0; i < 4; i++)
                sub_sr[i] <= {2'b00, sub[i][55:2]};
            header_sr <= {1'b0, header[23:1]};
        end
        else
        begin
            for (int i = 0; i < 4; i++)
                sub_sr[i] <= {2'b00, sub_sr[i][55:2]};
            header_sr <= {1'b0, header_sr[23:1]};
        end
    end
end

// The data bits sent this cycle, and fed to the ECC: subpacket bits
// 2*counter and 2*counter+1, header bit counter.
logic [1:0] sub_d [3:0];
logic header_d;
genvar i;
generate
    for (i = 0; i < 4; i++)
        assign sub_d[i] = counter == 5'd0 ? sub[i][1:0] : sub_sr[i][1:0];
endgenerate
assign header_d = counter == 5'd0 ? header[0] : header_sr[0];

// Initialize parity bits to 0
logic [7:0] parity [4:0] = '{8'd0, 8'd0, 8'd0, 8'd0, 8'd0};

// BCH packets 0 to 3 are transferred two bits at a time, see Section 5.2.3.4
// for further information: 28 cycles of subpacket data then the 8 parity
// bits; the header channel sends 24 header bits then its 8 parity bits.
logic [1:0] sub_out [3:0];
logic header_out;
generate
    for (i = 0; i < 4; i++)
        assign sub_out[i] = counter < 5'd28 ? sub_d[i] : parity[i][{counter[1:0], 1'b0} +: 2];
endgenerate
assign header_out = counter < 5'd24 ? header_d : parity[4][counter - 5'd24];
assign packet_data = {sub_out[3][1], sub_out[2][1], sub_out[1][1], sub_out[0][1],
                      sub_out[3][0], sub_out[2][0], sub_out[1][0], sub_out[0][0], header_out};

// See Figure 5-5 Error Correction Code generator. Generalization of a CRC with binary BCH.
// See https://web.archive.org/web/20190520020602/http://hamsterworks.co.nz/mediawiki/index.php/Minimal_HDMI#Computing_the_ECC for an explanation of the implementation.
// See https://en.wikipedia.org/wiki/BCH_code#Systematic_encoding:_The_message_as_a_prefix for further information.
function automatic [7:0] next_ecc;
input [7:0] ecc, next_bch_bit;
begin
    next_ecc = (ecc >> 1) ^ ((ecc[0] ^ next_bch_bit) ? 8'b10000011 : 8'd0);
end
endfunction

logic [7:0] parity_next [4:0];

// The parity needs to be calculated 2 bits at a time for blocks 0 to 3.
// There's 56 bits being sent 2 bits at a time over TMDS channels 1 & 2, so the parity bits wouldn't be ready in time otherwise.
logic [7:0] parity_next_next [3:0];

generate
    for(i = 0; i < 5; i++)
    begin: parity_calc
        if (i == 4)
            assign parity_next[i] = next_ecc(parity[i], header_d);
        else
        begin
            assign parity_next[i] = next_ecc(parity[i], sub_d[i][0]);
            assign parity_next_next[i] = next_ecc(parity_next[i], sub_d[i][1]);
        end
    end
endgenerate

always_ff @(posedge clk_pixel)
begin
    if (reset)
        parity <= '{8'd0, 8'd0, 8'd0, 8'd0, 8'd0};
    else if (data_island_period)
    begin
        if (counter < 5'd28) // Compute ECC only on subpacket data, not on itself
        begin
            parity[3:0] <= parity_next_next;
            if (counter < 5'd24) // Header only has 24 bits, whereas subpackets have 56 and 56 / 2 = 28.
                parity[4] <= parity_next[4];
        end
        else if (counter == 5'd31)
            parity <= '{8'd0, 8'd0, 8'd0, 8'd0, 8'd0}; // Reset ECC for next packet
    end
    else
        parity <= '{8'd0, 8'd0, 8'd0, 8'd0, 8'd0};
end

endmodule
