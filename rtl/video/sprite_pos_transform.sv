// SPDX-License-Identifier: GPL-3.0-or-later
// Position offset and zoom transform between decoding a sprite record and iterating its sub-tiles,
// from MAME's generic sprite path (get_sprites, psikyo_v.cpp:235-239):
//
//   x += (nx * zoomx_raw + 2) / 4          -- offset correction, uses RAW zoom
//   y += (ny * zoomy_raw + 2) / 4
//   zoomx = 32 - zoomx_raw                  -- THEN the raw->transformed zoom
//   zoomy = 32 - zoomy_raw
//
// The offset correction uses the raw (0-15) zoom, before the 32-raw transform. This board has no
// zoom -- sprite_record_decode drives zoom_*_raw to 0 -- so x_adj/y_adj are the input positions and
// both transformed zooms are 32.
//
// Screen flip is not handled here: the core renders the mirrored source line and reads the line
// buffer right to left instead (dreamworld_core.sv), flipping sprites and tilemaps together.

module sprite_pos_transform (
	input  logic signed [9:0] x_pos,
	input  logic signed [9:0] y_pos,
	input  logic [3:0]        nx,           // 1-8
	input  logic [3:0]        ny,           // 1-8
	input  logic [3:0]        zoom_x_raw,   // 0-15
	input  logic [3:0]        zoom_y_raw,   // 0-15

	output logic signed [9:0] x_adj,
	output logic signed [9:0] y_adj,
	output logic [5:0]        zoom_x_transformed,   // 17-32
	output logic [5:0]        zoom_y_transformed    // 17-32
);

	logic [6:0] x_prod, y_prod;      // nx(4b, max 8) * zoom_raw(4b, max 15) = max 120, 7 bits
	logic [4:0] x_offset, y_offset;  // (prod+2)>>2, max (120+2)>>2 = 30, 5 bits

	assign x_prod   = {3'd0, nx} * {3'd0, zoom_x_raw};
	assign x_offset = (x_prod + 7'd2) >> 2;
	assign x_adj    = x_pos + $signed({5'd0, x_offset});

	assign y_prod   = {3'd0, ny} * {3'd0, zoom_y_raw};
	assign y_offset = (y_prod + 7'd2) >> 2;
	assign y_adj    = y_pos + $signed({5'd0, y_offset});

	assign zoom_x_transformed = 6'd32 - {2'd0, zoom_x_raw};
	assign zoom_y_transformed = 6'd32 - {2'd0, zoom_y_raw};

endmodule
