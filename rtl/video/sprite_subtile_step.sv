// SPDX-License-Identifier: GPL-3.0-or-later
// One 16x16 sub-tile's screen position and raw gfx code, from MAME's sprite sub-tile loop
// (get_sprites, psikyo_v.cpp):
//
//   for (dy = flipy ? ny-1 .. 0 : 0 .. ny-1)
//     for (dx = flipx ? nx-1 .. 0 : 0 .. nx-1) {
//       sprite.code = spritelut[code & (lutlen-1)];   // next stage, not here
//       sprite.x    = x + (dx * zoomx) / 2;           // zoomx is the transformed (32-raw) value
//       sprite.y    = y + (dy * zoomy) / 2;
//       code++;
//     }
//
// Two things that are easy to get backwards:
//
// 1. dx/dy are both the position-grid index and the loop counter. Under flip they still range over
//    0..nx-1 (resp. 0..ny-1), just visited descending. The caller supplies natural, flip-unaware
//    ix/iy; this module applies the nx-1-ix / ny-1-iy reversal itself.
// 2. code increments per inner-loop iteration, in VISITATION order, so it follows the reversed
//    order under flip. The caller counts `subtile_ordinal` monotonically over the same sequence;
//    this module only adds it to the base code.
//
// This board has no zoom, so zoomx/zoomy are 32 and the step is dx*16 / dy*16. The C++'s zoom==32
// fast path is the same arithmetic, not a separate hardware case.
//
// The spritelut indirection (code -> gfx tile number) is a later stage; this module emits the raw
// code the LUT is indexed with.
//
// Widths: the swept input domain (x -128..383, y -256..255, nx/ny 1-8, zoom 0-15) gives
// X:[-128,495], Y:[-256,367], inside signed 10-bit, so sub_x/sub_y match x_adj/y_adj's width.

module sprite_subtile_step (
	input  logic [3:0]        ix,                  // 0..nx-1, natural (flip-unaware) column index
	input  logic [3:0]        iy,                  // 0..ny-1, natural (flip-unaware) row index
	input  logic [3:0]        nx,                  // 1-8
	input  logic [3:0]        ny,                  // 1-8
	input  logic              flip_x,
	input  logic              flip_y,
	input  logic signed [9:0] x_adj,
	input  logic signed [9:0] y_adj,
	input  logic [5:0]        zoom_x_transformed,  // 17-32
	input  logic [5:0]        zoom_y_transformed,  // 17-32
	input  logic [5:0]        subtile_ordinal,     // 0-63, visitation-order iteration count
	input  logic [16:0]       code_base,

	output logic signed [9:0] sub_x,
	output logic signed [9:0] sub_y,
	output logic [16:0]       sub_code
);

	logic [3:0] dx_grid, dy_grid;    // real range 0-7

	assign dx_grid = flip_x ? (nx - 4'd1 - ix) : ix;
	assign dy_grid = flip_y ? (ny - 4'd1 - iy) : iy;

	logic [7:0] x_step_prod, y_step_prod;  // dx_grid(max 7) * zoom(max 32) = max 224
	logic [6:0] x_step, y_step;            // >>1 of the above, max 112

	assign x_step_prod = {4'd0, dx_grid} * {2'd0, zoom_x_transformed};
	assign x_step       = x_step_prod[7:1];
	assign sub_x         = x_adj + $signed({3'd0, x_step});

	assign y_step_prod = {4'd0, dy_grid} * {2'd0, zoom_y_transformed};
	assign y_step       = y_step_prod[7:1];
	assign sub_y         = y_adj + $signed({3'd0, y_step});

	assign sub_code = code_base + {11'd0, subtile_ordinal};

endmodule
