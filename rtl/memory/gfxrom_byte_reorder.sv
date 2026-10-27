// SPDX-License-Identifier: GPL-3.0-or-later
// The seam between two opposite byte orders: sdram.sv returns a granule in ascending address,
// ascending bit position, while the tile and sprite readers want MAME's packed-MSB tile format, the
// byte at the lowest ROM address in bits [63:56]. Both sides are right for their own consumers, so
// the swap belongs here: the 16- and 8-bit readers behind sdram_narrow_bridge.sv (maincpu, the
// spritelut, the OKIs) are correct without it.
//
// Uniform gfx ROM content is byte-order invariant, so only non-uniform content exercises this.

module gfxrom_byte_reorder (
	input  logic [63:0] sdram_granule,
	output logic [63:0] gfxrom_data
);

	assign gfxrom_data = {sdram_granule[7:0],   sdram_granule[15:8],
							sdram_granule[23:16], sdram_granule[31:24],
							sdram_granule[39:32], sdram_granule[47:40],
							sdram_granule[55:48], sdram_granule[63:56]};

endmodule
