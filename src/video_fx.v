// Video filters for the TangCore scalers (the same file is in every core): colour
// controls, CRT mask and LCD grid. Needs scanlines.v (sl_dim).
//
// video_config bits (the firmware sets them, they may change at any time):
//   [2:0]   brightness, signed -4..+3: add 16 * n to every channel
//   [5:3]   contrast, signed -4..+3: c = 128 + (c - 128) * (8 + n) / 8
//   [8:6]   saturation, signed -4..+3: c = Y + (c - Y) * (4 + n) / 4,
//           Y = (77 R + 150 G + 29 B) >> 8 (-4 = greyscale)
//   [10:9]  gamma: 0 = none, 1 = darker (1.2), 2 = brighter (0.83), 3 = CRT (2.4 / 2.2)
//   [12:11] CRT mask: 0 = off, 1 = aperture grille, 2 = slot mask, 3 = dot mask
//   [14:13] mask strength: the dimmed channels lose 1/4, 3/8, 1/2, 5/8
//   [15]    LCD grid on
//   [17:16] grid strength: the grid pixels lose 1/8, 1/4, 3/8, 1/2
//   [19:18] reserved (smoothing)
//   [31:20] reserved
// All zero = no change: the output is then bit-identical to the input, FX_LAT (10)
// clocks later. So is any word with brightness, contrast, saturation, gamma, mask
// type and grid all 0, whatever the strengths say.
//
// video_fx replaces the scaler's sl_dim. The order of the stages:
//   colour    brightness, contrast, saturation, gamma
//   sl_dim    the scanline darkening, so a 100 % scanline stays black
//   grid/mask LCD grid and CRT mask, in one multiply
// Every channel is clamped to 0..255 after each colour step; the divisions
// round to nearest (half up), the grid/mask multiply rounds down. The colour
// stage is a fixed pipeline: its latency does not depend on the settings.
//
// The scaler hands over, aligned with rgb_in (the clock after the palette or
// frame buffer lookup):
//   pic_in       1 for a pixel of the game picture, 0 for the border and the
//                menu overlay. Those pass through unchanged.
//   dark_in      the scanline darkening (sl_rows `dark`, 0 outside the picture)
//   col_last_in  the last output column of a source pixel (LCD grid; 0 when
//                the horizontal scale is not a whole number)
//   row_last_in  the last output row of a source line (sl_rows `last`)
// and has to start the picture FX_LAT - 1 clocks earlier than it did with sl_dim
// alone (nes2hdmi.sv: `active` starts at XSTART - 1 - FX_LAT instead of XSTART - 2).
// The grid needs the integer scale (whole output rows per source line, whole
// output columns per source pixel): the scaler feeds video_config[15] to sl_rows
// `cfg_grid`, takes `last` as row_last_in and flags the columns itself.
//
// CRT mask, output pixels cx 0..1279, cy 0..719 (cx is the hdmi module's
// counter, pixel x is the rgb_out seen while cx = x). p = x mod 3:
//   grille  p = 0 keeps R, 1 keeps G, 2 keeps B; the other two channels are dimmed
//   slot    the grille, and all three channels of a triad (3 columns) are dimmed
//           on one row in 4: cy mod 4 = 0 for even triads, 2 for odd (x div 3)
//   dot     the grille with p = (x + cy[0]) mod 3, so the dots stagger on odd rows
// LCD grid: a pixel is dimmed if col_last_in or row_last_in; with the mask, the
// two multiply.

module video_fx (
    input         clk,              // pixel clock, 74.25 MHz
    input  [10:0] cx,               // from the hdmi module
    input  [9:0]  cy,
    input  [31:0] video_config,     // any clock domain

    input  [23:0] rgb_in,           // the picture, before the scanline darkening
    input         pic_in,
    input         dark_in,
    input  [1:0]  darkness,         // sl_rows `darkness`, a setting (not delayed with the pixel)
    input         col_last_in,
    input         row_last_in,

    output [23:0] rgb_out           // FX_LAT clocks after rgb_in
);

    localparam FX_LAT = 10;         // 8 colour stages, sl_dim, grid/mask

    // settings: synchronised to the pixel clock, latched at the start of every frame
    reg [17:0] cfg_a, cfg_b;
    reg [17:0] cfg = 18'd0;
    reg        cy0_r = 1'b1;
    always @(posedge clk) begin
        cfg_a <= video_config[17:0];
        cfg_b <= cfg_a;
        cy0_r <= (cy == 10'd0);
        if (cy == 10'd0 && !cy0_r)
            cfg <= cfg_b;
    end
    wire [2:0] f_bright   = cfg[2:0];
    wire [2:0] f_contrast = cfg[5:3];
    wire [2:0] f_sat      = cfg[8:6];
    wire [1:0] f_gamma    = cfg[10:9];
    wire [1:0] f_mask     = cfg[12:11];
    wire [1:0] f_mask_str = cfg[14:13];
    wire       f_grid     = cfg[15];
    wire [1:0] f_grid_str = cfg[17:16];

    // The flags that go with the pixel, delayed like it: *_d[n] is n clocks old.
    // The colour stages use the neutral setting for a pixel that is not the picture.
    reg [8:1] pic_r, dark_r, grid_r;
    always @(posedge clk) begin
        pic_r  <= {pic_r[7:1],  pic_in};
        dark_r <= {dark_r[7:1], dark_in};
        grid_r <= {grid_r[7:1], (col_last_in | row_last_in) & pic_in};
    end
    wire [8:0] pic_d  = {pic_r, pic_in};
    wire [8:1] dark_d = dark_r;
    wire [8:1] grid_d = grid_r;

    function [7:0] clamp8(input signed [13:0] v);
        clamp8 = v[13] ? 8'd0 : (v > 14'sd255) ? 8'd255 : v[7:0];
    endfunction

    genvar k;

    // 1: brightness  2: contrast multiply  3: contrast divide
    wire [2:0] b_eff = pic_d[0] ? f_bright : 3'd0;
    wire signed [13:0] b_off = {{7{b_eff[2]}}, b_eff, 4'b0000};
    wire [3:0] c_fac = pic_d[1] ? 4'd8 + {f_contrast[2], f_contrast} : 4'd8;
    wire [23:0] c3;
    generate for (k = 0; k < 3; k = k + 1) begin : bc
        reg [7:0] s1;
        reg signed [12:0] p2;
        reg [7:0] s3;
        wire signed [7:0] centred = s1 ^ 8'h80;             // c - 128
        wire signed [4:0] fac = {1'b0, c_fac};
        wire signed [13:0] scaled = ($signed(p2) + 14'sd4) >>> 3;
        always @(posedge clk) begin
            s1 <= clamp8($signed({6'd0, rgb_in[8*k +: 8]}) + b_off);
            p2 <= centred * fac;
            s3 <= clamp8(scaled + 14'sd128);
        end
        assign c3[8*k +: 8] = s3;
    end endgenerate

    // 4: luma partial products  5: luma
    reg [15:0] lr, lg, lb;
    reg [23:0] c4, c5;
    reg [7:0]  y5;
    wire [15:0] ysum = lr + lg + lb;
    always @(posedge clk) begin
        lr <= 16'd77  * c3[23:16];
        lg <= 16'd150 * c3[15:8];
        lb <= 16'd29  * c3[7:0];
        c4 <= c3;
        y5 <= ysum[15:8];
        c5 <= c4;
    end

    // 6: saturation multiply  7: saturation divide
    wire [2:0] s_fac = pic_d[5] ? 3'd4 + f_sat : 3'd4;
    reg  [7:0] y6;
    wire [23:0] c7;
    always @(posedge clk) y6 <= y5;
    generate for (k = 0; k < 3; k = k + 1) begin : sat
        reg signed [11:0] p6;
        reg [7:0] s7;
        wire signed [8:0] diff = $signed({1'b0, c5[8*k +: 8]}) - $signed({1'b0, y5});
        wire signed [3:0] fac = {1'b0, s_fac};
        wire signed [13:0] scaled = ($signed(p6) + 14'sd2) >>> 2;
        always @(posedge clk) begin
            p6 <= diff * fac;
            s7 <= clamp8($signed({6'd0, y6}) + scaled);
        end
        assign c7[8*k +: 8] = s7;
    end endgenerate

    // 8: gamma, 256-entry tables (the lookup is the stage)
    wire [1:0]  g_eff = pic_d[7] ? f_gamma : 2'd0;
    wire [23:0] rgb_c;
    generate for (k = 0; k < 3; k = k + 1) begin : gam
        fx_gamma_rom rom (.clk(clk), .addr({g_eff, c7[8*k +: 8]}), .q(rgb_c[8*k +: 8]));
    end endgenerate

    // the scanline darkening
    wire [23:0] rgb_d;
    sl_dim dim (.clk(clk), .rgb_in(rgb_c), .dark(dark_d[8]), .darkness(darkness), .rgb_out(rgb_d));

    // Grid and mask factors in 1/64, registered next to the dimmed pixel (clock 9).
    // They are computed for the pixel that will be output two clocks later, x = cx + MASK_LEAD:
    // p3 = x mod 3 and trd = (x div 3) mod 2 count along cx, restarted on the first column
    // of a row (the clock after it holds x = 1 + MASK_LEAD).
    localparam MASK_LEAD = 2;
    localparam P3_0  = (1 + MASK_LEAD) % 3;
    localparam TRD_0 = ((1 + MASK_LEAD) / 3) % 2;
    reg [1:0] p3;
    reg       trd;
    always @(posedge clk) begin
        if (cx == 11'd0) begin
            p3  <= P3_0;
            trd <= TRD_0;
        end else if (p3 == 2'd2) begin
            p3  <= 2'd0;
            trd <= ~trd;
        end else
            p3  <= p3 + 2'd1;
    end

    wire [1:0] phase    = (f_mask == 2'd3 && cy[0]) ? (p3 == 2'd2 ? 2'd0 : p3 + 2'd1) : p3;
    wire       slot_row = (f_mask == 2'd2) && (cy[1:0] == (trd ? 2'd2 : 2'd0));
    wire [3:0] m_fac    = 4'd6 - {2'b00, f_mask_str};       // 8 - (2 + strength)
    wire [3:0] g_fac    = (f_grid && grid_d[8]) ? 4'd7 - {2'b00, f_grid_str} : 4'd8;  // 8 - (1 + strength)

    reg [6:0]  fac_r, fac_g, fac_b;
    always @(posedge clk) begin
        fac_r <= (pic_d[8] && f_mask != 2'd0 && (phase != 2'd0 || slot_row) ? m_fac : 4'd8) * g_fac;
        fac_g <= (pic_d[8] && f_mask != 2'd0 && (phase != 2'd1 || slot_row) ? m_fac : 4'd8) * g_fac;
        fac_b <= (pic_d[8] && f_mask != 2'd0 && (phase != 2'd2 || slot_row) ? m_fac : 4'd8) * g_fac;
    end

    // 10: the multiply
    reg [13:0] out_r, out_g, out_b;
    always @(posedge clk) begin
        out_r <= rgb_d[23:16] * fac_r;
        out_g <= rgb_d[15:8]  * fac_g;
        out_b <= rgb_d[7:0]   * fac_b;
    end
    assign rgb_out = {out_r[13:6], out_g[13:6], out_b[13:6]};

endmodule


// Gamma tables: {gamma, value} -> value, one register stage (a block RAM ROM).
module fx_gamma_rom (
    input            clk,
    input      [9:0] addr,
    output reg [7:0] q
);

    reg [7:0] rom [0:1023] /* synthesis syn_romstyle="block_rom" */;

    initial begin
    // BEGIN gamma tables (tools/video_fx_gamma.py)
    // gamma 1
    rom[0]=0; rom[1]=1; rom[2]=2; rom[3]=3; rom[4]=4; rom[5]=5; rom[6]=6; rom[7]=7;
    rom[8]=8; rom[9]=9; rom[10]=10; rom[11]=11; rom[12]=12; rom[13]=13; rom[14]=14; rom[15]=15;
    rom[16]=16; rom[17]=17; rom[18]=18; rom[19]=19; rom[20]=20; rom[21]=21; rom[22]=22; rom[23]=23;
    rom[24]=24; rom[25]=25; rom[26]=26; rom[27]=27; rom[28]=28; rom[29]=29; rom[30]=30; rom[31]=31;
    rom[32]=32; rom[33]=33; rom[34]=34; rom[35]=35; rom[36]=36; rom[37]=37; rom[38]=38; rom[39]=39;
    rom[40]=40; rom[41]=41; rom[42]=42; rom[43]=43; rom[44]=44; rom[45]=45; rom[46]=46; rom[47]=47;
    rom[48]=48; rom[49]=49; rom[50]=50; rom[51]=51; rom[52]=52; rom[53]=53; rom[54]=54; rom[55]=55;
    rom[56]=56; rom[57]=57; rom[58]=58; rom[59]=59; rom[60]=60; rom[61]=61; rom[62]=62; rom[63]=63;
    rom[64]=64; rom[65]=65; rom[66]=66; rom[67]=67; rom[68]=68; rom[69]=69; rom[70]=70; rom[71]=71;
    rom[72]=72; rom[73]=73; rom[74]=74; rom[75]=75; rom[76]=76; rom[77]=77; rom[78]=78; rom[79]=79;
    rom[80]=80; rom[81]=81; rom[82]=82; rom[83]=83; rom[84]=84; rom[85]=85; rom[86]=86; rom[87]=87;
    rom[88]=88; rom[89]=89; rom[90]=90; rom[91]=91; rom[92]=92; rom[93]=93; rom[94]=94; rom[95]=95;
    rom[96]=96; rom[97]=97; rom[98]=98; rom[99]=99; rom[100]=100; rom[101]=101; rom[102]=102; rom[103]=103;
    rom[104]=104; rom[105]=105; rom[106]=106; rom[107]=107; rom[108]=108; rom[109]=109; rom[110]=110; rom[111]=111;
    rom[112]=112; rom[113]=113; rom[114]=114; rom[115]=115; rom[116]=116; rom[117]=117; rom[118]=118; rom[119]=119;
    rom[120]=120; rom[121]=121; rom[122]=122; rom[123]=123; rom[124]=124; rom[125]=125; rom[126]=126; rom[127]=127;
    rom[128]=128; rom[129]=129; rom[130]=130; rom[131]=131; rom[132]=132; rom[133]=133; rom[134]=134; rom[135]=135;
    rom[136]=136; rom[137]=137; rom[138]=138; rom[139]=139; rom[140]=140; rom[141]=141; rom[142]=142; rom[143]=143;
    rom[144]=144; rom[145]=145; rom[146]=146; rom[147]=147; rom[148]=148; rom[149]=149; rom[150]=150; rom[151]=151;
    rom[152]=152; rom[153]=153; rom[154]=154; rom[155]=155; rom[156]=156; rom[157]=157; rom[158]=158; rom[159]=159;
    rom[160]=160; rom[161]=161; rom[162]=162; rom[163]=163; rom[164]=164; rom[165]=165; rom[166]=166; rom[167]=167;
    rom[168]=168; rom[169]=169; rom[170]=170; rom[171]=171; rom[172]=172; rom[173]=173; rom[174]=174; rom[175]=175;
    rom[176]=176; rom[177]=177; rom[178]=178; rom[179]=179; rom[180]=180; rom[181]=181; rom[182]=182; rom[183]=183;
    rom[184]=184; rom[185]=185; rom[186]=186; rom[187]=187; rom[188]=188; rom[189]=189; rom[190]=190; rom[191]=191;
    rom[192]=192; rom[193]=193; rom[194]=194; rom[195]=195; rom[196]=196; rom[197]=197; rom[198]=198; rom[199]=199;
    rom[200]=200; rom[201]=201; rom[202]=202; rom[203]=203; rom[204]=204; rom[205]=205; rom[206]=206; rom[207]=207;
    rom[208]=208; rom[209]=209; rom[210]=210; rom[211]=211; rom[212]=212; rom[213]=213; rom[214]=214; rom[215]=215;
    rom[216]=216; rom[217]=217; rom[218]=218; rom[219]=219; rom[220]=220; rom[221]=221; rom[222]=222; rom[223]=223;
    rom[224]=224; rom[225]=225; rom[226]=226; rom[227]=227; rom[228]=228; rom[229]=229; rom[230]=230; rom[231]=231;
    rom[232]=232; rom[233]=233; rom[234]=234; rom[235]=235; rom[236]=236; rom[237]=237; rom[238]=238; rom[239]=239;
    rom[240]=240; rom[241]=241; rom[242]=242; rom[243]=243; rom[244]=244; rom[245]=245; rom[246]=246; rom[247]=247;
    rom[248]=248; rom[249]=249; rom[250]=250; rom[251]=251; rom[252]=252; rom[253]=253; rom[254]=254; rom[255]=255;
    // gamma 1.2
    rom[256]=0; rom[257]=0; rom[258]=1; rom[259]=1; rom[260]=2; rom[261]=2; rom[262]=3; rom[263]=3;
    rom[264]=4; rom[265]=5; rom[266]=5; rom[267]=6; rom[268]=7; rom[269]=7; rom[270]=8; rom[271]=9;
    rom[272]=9; rom[273]=10; rom[274]=11; rom[275]=11; rom[276]=12; rom[277]=13; rom[278]=13; rom[279]=14;
    rom[280]=15; rom[281]=16; rom[282]=16; rom[283]=17; rom[284]=18; rom[285]=19; rom[286]=20; rom[287]=20;
    rom[288]=21; rom[289]=22; rom[290]=23; rom[291]=24; rom[292]=24; rom[293]=25; rom[294]=26; rom[295]=27;
    rom[296]=28; rom[297]=28; rom[298]=29; rom[299]=30; rom[300]=31; rom[301]=32; rom[302]=33; rom[303]=34;
    rom[304]=34; rom[305]=35; rom[306]=36; rom[307]=37; rom[308]=38; rom[309]=39; rom[310]=40; rom[311]=40;
    rom[312]=41; rom[313]=42; rom[314]=43; rom[315]=44; rom[316]=45; rom[317]=46; rom[318]=47; rom[319]=48;
    rom[320]=49; rom[321]=49; rom[322]=50; rom[323]=51; rom[324]=52; rom[325]=53; rom[326]=54; rom[327]=55;
    rom[328]=56; rom[329]=57; rom[330]=58; rom[331]=59; rom[332]=60; rom[333]=61; rom[334]=62; rom[335]=62;
    rom[336]=63; rom[337]=64; rom[338]=65; rom[339]=66; rom[340]=67; rom[341]=68; rom[342]=69; rom[343]=70;
    rom[344]=71; rom[345]=72; rom[346]=73; rom[347]=74; rom[348]=75; rom[349]=76; rom[350]=77; rom[351]=78;
    rom[352]=79; rom[353]=80; rom[354]=81; rom[355]=82; rom[356]=83; rom[357]=84; rom[358]=85; rom[359]=86;
    rom[360]=87; rom[361]=88; rom[362]=89; rom[363]=90; rom[364]=91; rom[365]=92; rom[366]=93; rom[367]=94;
    rom[368]=95; rom[369]=96; rom[370]=97; rom[371]=98; rom[372]=99; rom[373]=100; rom[374]=101; rom[375]=102;
    rom[376]=103; rom[377]=104; rom[378]=105; rom[379]=106; rom[380]=107; rom[381]=108; rom[382]=109; rom[383]=110;
    rom[384]=112; rom[385]=113; rom[386]=114; rom[387]=115; rom[388]=116; rom[389]=117; rom[390]=118; rom[391]=119;
    rom[392]=120; rom[393]=121; rom[394]=122; rom[395]=123; rom[396]=124; rom[397]=125; rom[398]=126; rom[399]=127;
    rom[400]=128; rom[401]=130; rom[402]=131; rom[403]=132; rom[404]=133; rom[405]=134; rom[406]=135; rom[407]=136;
    rom[408]=137; rom[409]=138; rom[410]=139; rom[411]=140; rom[412]=141; rom[413]=142; rom[414]=144; rom[415]=145;
    rom[416]=146; rom[417]=147; rom[418]=148; rom[419]=149; rom[420]=150; rom[421]=151; rom[422]=152; rom[423]=153;
    rom[424]=155; rom[425]=156; rom[426]=157; rom[427]=158; rom[428]=159; rom[429]=160; rom[430]=161; rom[431]=162;
    rom[432]=163; rom[433]=165; rom[434]=166; rom[435]=167; rom[436]=168; rom[437]=169; rom[438]=170; rom[439]=171;
    rom[440]=172; rom[441]=173; rom[442]=175; rom[443]=176; rom[444]=177; rom[445]=178; rom[446]=179; rom[447]=180;
    rom[448]=181; rom[449]=183; rom[450]=184; rom[451]=185; rom[452]=186; rom[453]=187; rom[454]=188; rom[455]=189;
    rom[456]=191; rom[457]=192; rom[458]=193; rom[459]=194; rom[460]=195; rom[461]=196; rom[462]=197; rom[463]=199;
    rom[464]=200; rom[465]=201; rom[466]=202; rom[467]=203; rom[468]=204; rom[469]=205; rom[470]=207; rom[471]=208;
    rom[472]=209; rom[473]=210; rom[474]=211; rom[475]=212; rom[476]=214; rom[477]=215; rom[478]=216; rom[479]=217;
    rom[480]=218; rom[481]=219; rom[482]=221; rom[483]=222; rom[484]=223; rom[485]=224; rom[486]=225; rom[487]=226;
    rom[488]=228; rom[489]=229; rom[490]=230; rom[491]=231; rom[492]=232; rom[493]=234; rom[494]=235; rom[495]=236;
    rom[496]=237; rom[497]=238; rom[498]=239; rom[499]=241; rom[500]=242; rom[501]=243; rom[502]=244; rom[503]=245;
    rom[504]=247; rom[505]=248; rom[506]=249; rom[507]=250; rom[508]=251; rom[509]=253; rom[510]=254; rom[511]=255;
    // gamma 0.83
    rom[512]=0; rom[513]=3; rom[514]=5; rom[515]=6; rom[516]=8; rom[517]=10; rom[518]=11; rom[519]=13;
    rom[520]=14; rom[521]=16; rom[522]=17; rom[523]=19; rom[524]=20; rom[525]=22; rom[526]=23; rom[527]=24;
    rom[528]=26; rom[529]=27; rom[530]=28; rom[531]=30; rom[532]=31; rom[533]=32; rom[534]=33; rom[535]=35;
    rom[536]=36; rom[537]=37; rom[538]=38; rom[539]=40; rom[540]=41; rom[541]=42; rom[542]=43; rom[543]=44;
    rom[544]=46; rom[545]=47; rom[546]=48; rom[547]=49; rom[548]=50; rom[549]=51; rom[550]=53; rom[551]=54;
    rom[552]=55; rom[553]=56; rom[554]=57; rom[555]=58; rom[556]=59; rom[557]=60; rom[558]=62; rom[559]=63;
    rom[560]=64; rom[561]=65; rom[562]=66; rom[563]=67; rom[564]=68; rom[565]=69; rom[566]=70; rom[567]=71;
    rom[568]=72; rom[569]=74; rom[570]=75; rom[571]=76; rom[572]=77; rom[573]=78; rom[574]=79; rom[575]=80;
    rom[576]=81; rom[577]=82; rom[578]=83; rom[579]=84; rom[580]=85; rom[581]=86; rom[582]=87; rom[583]=88;
    rom[584]=89; rom[585]=90; rom[586]=91; rom[587]=92; rom[588]=93; rom[589]=94; rom[590]=95; rom[591]=96;
    rom[592]=97; rom[593]=98; rom[594]=99; rom[595]=100; rom[596]=101; rom[597]=102; rom[598]=103; rom[599]=104;
    rom[600]=105; rom[601]=106; rom[602]=107; rom[603]=108; rom[604]=109; rom[605]=110; rom[606]=111; rom[607]=112;
    rom[608]=113; rom[609]=114; rom[610]=115; rom[611]=116; rom[612]=117; rom[613]=118; rom[614]=119; rom[615]=120;
    rom[616]=121; rom[617]=122; rom[618]=123; rom[619]=124; rom[620]=125; rom[621]=126; rom[622]=127; rom[623]=128;
    rom[624]=129; rom[625]=130; rom[626]=131; rom[627]=132; rom[628]=133; rom[629]=134; rom[630]=135; rom[631]=135;
    rom[632]=136; rom[633]=137; rom[634]=138; rom[635]=139; rom[636]=140; rom[637]=141; rom[638]=142; rom[639]=143;
    rom[640]=144; rom[641]=145; rom[642]=146; rom[643]=147; rom[644]=148; rom[645]=149; rom[646]=149; rom[647]=150;
    rom[648]=151; rom[649]=152; rom[650]=153; rom[651]=154; rom[652]=155; rom[653]=156; rom[654]=157; rom[655]=158;
    rom[656]=159; rom[657]=160; rom[658]=161; rom[659]=161; rom[660]=162; rom[661]=163; rom[662]=164; rom[663]=165;
    rom[664]=166; rom[665]=167; rom[666]=168; rom[667]=169; rom[668]=170; rom[669]=170; rom[670]=171; rom[671]=172;
    rom[672]=173; rom[673]=174; rom[674]=175; rom[675]=176; rom[676]=177; rom[677]=178; rom[678]=179; rom[679]=179;
    rom[680]=180; rom[681]=181; rom[682]=182; rom[683]=183; rom[684]=184; rom[685]=185; rom[686]=186; rom[687]=187;
    rom[688]=187; rom[689]=188; rom[690]=189; rom[691]=190; rom[692]=191; rom[693]=192; rom[694]=193; rom[695]=194;
    rom[696]=194; rom[697]=195; rom[698]=196; rom[699]=197; rom[700]=198; rom[701]=199; rom[702]=200; rom[703]=201;
    rom[704]=201; rom[705]=202; rom[706]=203; rom[707]=204; rom[708]=205; rom[709]=206; rom[710]=207; rom[711]=208;
    rom[712]=208; rom[713]=209; rom[714]=210; rom[715]=211; rom[716]=212; rom[717]=213; rom[718]=214; rom[719]=214;
    rom[720]=215; rom[721]=216; rom[722]=217; rom[723]=218; rom[724]=219; rom[725]=220; rom[726]=220; rom[727]=221;
    rom[728]=222; rom[729]=223; rom[730]=224; rom[731]=225; rom[732]=226; rom[733]=226; rom[734]=227; rom[735]=228;
    rom[736]=229; rom[737]=230; rom[738]=231; rom[739]=232; rom[740]=232; rom[741]=233; rom[742]=234; rom[743]=235;
    rom[744]=236; rom[745]=237; rom[746]=237; rom[747]=238; rom[748]=239; rom[749]=240; rom[750]=241; rom[751]=242;
    rom[752]=242; rom[753]=243; rom[754]=244; rom[755]=245; rom[756]=246; rom[757]=247; rom[758]=248; rom[759]=248;
    rom[760]=249; rom[761]=250; rom[762]=251; rom[763]=252; rom[764]=253; rom[765]=253; rom[766]=254; rom[767]=255;
    // gamma 1.091
    rom[768]=0; rom[769]=1; rom[770]=1; rom[771]=2; rom[772]=3; rom[773]=3; rom[774]=4; rom[775]=5;
    rom[776]=6; rom[777]=7; rom[778]=7; rom[779]=8; rom[780]=9; rom[781]=10; rom[782]=11; rom[783]=12;
    rom[784]=12; rom[785]=13; rom[786]=14; rom[787]=15; rom[788]=16; rom[789]=17; rom[790]=18; rom[791]=18;
    rom[792]=19; rom[793]=20; rom[794]=21; rom[795]=22; rom[796]=23; rom[797]=24; rom[798]=25; rom[799]=26;
    rom[800]=26; rom[801]=27; rom[802]=28; rom[803]=29; rom[804]=30; rom[805]=31; rom[806]=32; rom[807]=33;
    rom[808]=34; rom[809]=35; rom[810]=36; rom[811]=37; rom[812]=38; rom[813]=38; rom[814]=39; rom[815]=40;
    rom[816]=41; rom[817]=42; rom[818]=43; rom[819]=44; rom[820]=45; rom[821]=46; rom[822]=47; rom[823]=48;
    rom[824]=49; rom[825]=50; rom[826]=51; rom[827]=52; rom[828]=53; rom[829]=54; rom[830]=55; rom[831]=55;
    rom[832]=56; rom[833]=57; rom[834]=58; rom[835]=59; rom[836]=60; rom[837]=61; rom[838]=62; rom[839]=63;
    rom[840]=64; rom[841]=65; rom[842]=66; rom[843]=67; rom[844]=68; rom[845]=69; rom[846]=70; rom[847]=71;
    rom[848]=72; rom[849]=73; rom[850]=74; rom[851]=75; rom[852]=76; rom[853]=77; rom[854]=78; rom[855]=79;
    rom[856]=80; rom[857]=81; rom[858]=82; rom[859]=83; rom[860]=84; rom[861]=85; rom[862]=86; rom[863]=87;
    rom[864]=88; rom[865]=89; rom[866]=90; rom[867]=91; rom[868]=92; rom[869]=93; rom[870]=94; rom[871]=95;
    rom[872]=96; rom[873]=97; rom[874]=98; rom[875]=99; rom[876]=100; rom[877]=101; rom[878]=102; rom[879]=103;
    rom[880]=104; rom[881]=105; rom[882]=106; rom[883]=107; rom[884]=108; rom[885]=109; rom[886]=110; rom[887]=111;
    rom[888]=112; rom[889]=113; rom[890]=114; rom[891]=115; rom[892]=116; rom[893]=117; rom[894]=118; rom[895]=119;
    rom[896]=120; rom[897]=121; rom[898]=122; rom[899]=123; rom[900]=124; rom[901]=125; rom[902]=126; rom[903]=127;
    rom[904]=128; rom[905]=129; rom[906]=131; rom[907]=132; rom[908]=133; rom[909]=134; rom[910]=135; rom[911]=136;
    rom[912]=137; rom[913]=138; rom[914]=139; rom[915]=140; rom[916]=141; rom[917]=142; rom[918]=143; rom[919]=144;
    rom[920]=145; rom[921]=146; rom[922]=147; rom[923]=148; rom[924]=149; rom[925]=150; rom[926]=151; rom[927]=152;
    rom[928]=153; rom[929]=154; rom[930]=155; rom[931]=157; rom[932]=158; rom[933]=159; rom[934]=160; rom[935]=161;
    rom[936]=162; rom[937]=163; rom[938]=164; rom[939]=165; rom[940]=166; rom[941]=167; rom[942]=168; rom[943]=169;
    rom[944]=170; rom[945]=171; rom[946]=172; rom[947]=173; rom[948]=174; rom[949]=175; rom[950]=177; rom[951]=178;
    rom[952]=179; rom[953]=180; rom[954]=181; rom[955]=182; rom[956]=183; rom[957]=184; rom[958]=185; rom[959]=186;
    rom[960]=187; rom[961]=188; rom[962]=189; rom[963]=190; rom[964]=191; rom[965]=192; rom[966]=193; rom[967]=195;
    rom[968]=196; rom[969]=197; rom[970]=198; rom[971]=199; rom[972]=200; rom[973]=201; rom[974]=202; rom[975]=203;
    rom[976]=204; rom[977]=205; rom[978]=206; rom[979]=207; rom[980]=208; rom[981]=210; rom[982]=211; rom[983]=212;
    rom[984]=213; rom[985]=214; rom[986]=215; rom[987]=216; rom[988]=217; rom[989]=218; rom[990]=219; rom[991]=220;
    rom[992]=221; rom[993]=222; rom[994]=224; rom[995]=225; rom[996]=226; rom[997]=227; rom[998]=228; rom[999]=229;
    rom[1000]=230; rom[1001]=231; rom[1002]=232; rom[1003]=233; rom[1004]=234; rom[1005]=235; rom[1006]=237; rom[1007]=238;
    rom[1008]=239; rom[1009]=240; rom[1010]=241; rom[1011]=242; rom[1012]=243; rom[1013]=244; rom[1014]=245; rom[1015]=246;
    rom[1016]=247; rom[1017]=248; rom[1018]=250; rom[1019]=251; rom[1020]=252; rom[1021]=253; rom[1022]=254; rom[1023]=255;
    // END gamma tables
    end

    always @(posedge clk) q <= rom[addr];

endmodule
