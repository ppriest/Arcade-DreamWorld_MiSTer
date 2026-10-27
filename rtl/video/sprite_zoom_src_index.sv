// SPDX-License-Identifier: GPL-3.0-or-later
// Per-destination-column source pixel index for the nearest-neighbour zoom blit
// (gfx_element::drawgfxzoom_core, drawgfxt.ipp:738-805), as a closed form:
//
//   no flip: accum before column col = col * dx
//   flip:    accum before column col = (dst_size-1-col) * dx
//   src_index = accum >> 16
//
// dx is constant across a sub-tile row/column, so the C++'s running accumulator is an arithmetic
// progression and this is pure combinational per-column math. col is driven 0..dst_size-1; col >=
// dst_size is a don't-care.
//
// col*dx needs ~21 bits before the >>16, but src_index stays in 0-15 across every raw zoom value,
// both flip directions and every valid col (checked exhaustively in Python), so it never leaves
// the source tile.
//
// This board has no zoom: dst_size is 16 and dx is 1.0, so src_index is col (15-col when flipped).

module sprite_zoom_src_index (
	input  logic [3:0]  col,        // 0..dst_size-1 (caller-guaranteed)
	input  logic [3:0]  dst_size,   // 9-16, from sprite_zoom_lut
	input  logic [16:0] dx,         // 16.16 fixed-point step, from sprite_zoom_lut
	input  logic         flip,

	output logic [3:0]  src_index   // 0-15
);

	logic [3:0]  eff_col;
	logic [20:0] prod;   // col/eff_col (4b, max 15) * dx (17b, max 0x1C71C) needs 21 bits

	assign eff_col = flip ? (dst_size - 4'd1 - col) : col;
	assign prod     = {17'd0, eff_col} * {4'd0, dx};
	assign src_index = prod[19:16];

endmodule
