// SPDX-License-Identifier: GPL-3.0-or-later
// Decodes a raw 16-bit tilemap VRAM cell (vram_cell -- "cell" is a SystemVerilog keyword) into a
// gfx-ROM tile number and palette colour group, per get_tile_info<Layer> (dreamwld.cpp:282-283):
//
//   tile_number = vram_cell[12:0] + (bank << 13)
//   color       = vram_cell[15:13] + layer*0x40
//
// `bank` is the layer control word's bit 6 (dreamwld.cpp:334); this board exposes one bit, so 0 or
// 1. `layer` is a static per-instance parameter, not a runtime input.

module tile_cell_decode #(
	parameter int LAYER = 0   // 0 or 1
) (
	input  logic [15:0] vram_cell,
	input  logic [1:0]  bank,
	output logic [14:0] tile_number,
	output logic [6:0]  color
);

	// Concatenation-based bank/layer-offset construction throughout,
	// deliberately avoiding bare shift/multiply-by-parameter expressions --
	// see the tile_row_decode_tb commit message for why: Verilog's
	// self-determined operand widths inside arithmetic expressions are an
	// easy silent-corruption trap.
	localparam logic [6:0] LAYER_BASE = (LAYER != 0) ? 7'd64 : 7'd0;

	assign tile_number = {2'b00, vram_cell[12:0]} + {bank, 13'd0};
	assign color        = {4'b0000, vram_cell[15:13]} + LAYER_BASE;

endmodule
