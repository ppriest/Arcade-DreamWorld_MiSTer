// Decodes one sprite record, dreamwld.cpp draw_sprites (lines 203-260), as four 16-bit words
// (record n at sprite RAM word 4n):
//
//   word_y        source[0] >> 16:  ysize bits 11:9, y bits 8:0
//   word_x        source[0] & ffff: xsize bits 11:9, x bits 8:0
//   word_attr     source[1] >> 16:  yflip bit 15, xflip bit 14, colour bits 13:8, tileno bit 16 in bit 0
//   word_code_lo  source[1] & ffff: tileno bits 15:0
//
// MAME draws each tile at (X, Y), (X - 0x200, Y), (X - 0x200, Y - 0x200) and (X, Y - 0x200),
// with X = ((x + 4) & 0x1ff) - 16 and Y = y. A sprite is at most 128 pixels each way and the
// screen 308 x 224, so at most one copy is ever on screen, and one signed position per axis
// draws exactly what the four do:
//   Y: y - 0x200 when y >= 256 (9-bit sign extension). For y 256-383 neither copy is visible.
//   X: X - 0x200 when X >= 384, i.e. (x + 4) & 0x1ff >= 400. For X 308-383 neither is.
// The engine's zoom path is fed raw zoom 0 (16 pixels a tile, step 1): the board has no zoom.

module sprite_record_decode (
	input  logic [15:0] word_y,
	input  logic [15:0] word_x,
	input  logic [15:0] word_attr,
	input  logic [15:0] word_code_lo,

	output logic [3:0]        zoom_y_raw,   // always 0
	output logic [3:0]        zoom_x_raw,   // always 0
	output logic [3:0]        ny,           // 1-8
	output logic [3:0]        nx,           // 1-8
	output logic signed [9:0] y_pos,        // -256..255
	output logic signed [9:0] x_pos,        // -128..383
	output logic              flip_y,
	output logic              flip_x,
	output logic [5:0]        color,
	output logic [16:0]       code
);

	logic [8:0]         u;        // (x + 4) & 0x1ff
	logic signed [10:0] x_full;

	assign zoom_y_raw = 4'd0;
	assign zoom_x_raw = 4'd0;
	assign ny         = {1'b0, word_y[11:9]} + 4'd1;
	assign nx         = {1'b0, word_x[11:9]} + 4'd1;
	assign y_pos      = $signed({word_y[8], word_y[8:0]});
	assign u          = word_x[8:0] + 9'd4;
	assign x_full     = $signed({2'b00, u}) - ((u >= 9'd400) ? 11'sd528 : 11'sd16);
	assign x_pos      = x_full[9:0];   // -128..383

	assign flip_y = word_attr[15];
	assign flip_x = word_attr[14];
	assign color  = word_attr[13:8];
	assign code   = {word_attr[0], word_code_lo};

endmodule
