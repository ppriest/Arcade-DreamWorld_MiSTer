// SPDX-License-Identifier: GPL-3.0-or-later
// Decodes one 16-pixel row of a 16x16x4bpp packed-MSB tile (MAME's gfx_16x16x4_packed_msb, the
// format of both the sprite and tilemap gfx regions here) into 16 4-bit palette indices.
//
// Format, from MAME's decode algorithm (src/emu/drawgfx.cpp: gfx_element::decode()/readbit()),
// not from the gfx_layout struct alone:
//
//   - 8 bytes, byte-major, MSB-first: byte0 holds pixels 0-1, byte7 pixels 14-15.
//   - Each byte's HIGH nibble is the even (left) pixel, the LOW nibble the odd (right) one.
//   - The 4 bits map directly to the pixel's palette index -- no bit reversal.
//
// flip_x mirrors the whole 16-pixel row.

module tile_row_decode (
	input  logic [7:0] row_bytes [0:7],  // row_bytes[0] = leftmost byte (pixels 0,1)
	input  logic        flip_x,
	output logic [3:0]  pixel [0:15]     // pixel[0] = leftmost displayed pixel
);

	logic [3:0] natural [0:15];

	genvar gx;
	generate
		for (gx = 0; gx < 16; gx++) begin : g_natural
			// even x -> high nibble of byte[x/2], odd x -> low nibble
			assign natural[gx] = gx[0] ? row_bytes[gx/2][3:0] : row_bytes[gx/2][7:4];
		end
	endgenerate

	genvar gy;
	generate
		for (gy = 0; gy < 16; gy++) begin : g_out
			assign pixel[gy] = flip_x ? natural[15 - gy] : natural[gy];
		end
	endgenerate

endmodule
