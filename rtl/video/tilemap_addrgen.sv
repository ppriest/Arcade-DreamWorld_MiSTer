// SPDX-License-Identifier: GPL-3.0-or-later
// Tilemap VRAM address generator, one instance per layer.
//
// Computes the VRAM word index for a (col,row) tile coordinate under the current tilemap geometry.
// dreamwld has two: bit 10 of the layer control word selects 64x64 or 128x32 tiles
// (dreamwld.cpp:344). Modes 2 and 3 are the other two Psikyo geometries and are unreachable here,
// because vreg_decode drives mode as {1'b0, ctrl[10]}.
//
// In every mode MAME's tile_scan<Layer> (psikyo_v.cpp) looks like a bit interleave, but the caller
// masks the result to 12 bits and each extra term lands above bit 11, so all reduce to row-major
// addressing, index = col + row*width (checked exhaustively in sim/tilemap_addrgen_tb):
//   0 -> 64x64 tiles  (1024x1024 px), index = col[5:0] | row[5:0]<<6
//   1 -> 128x32 tiles (2048x512 px),  index = col[6:0] | row[4:0]<<7
//   2 -> 256x16 tiles (4096x256 px),  index = col[7:0] | row[3:0]<<8
//   3 -> 32x128 tiles (512x2048 px),  index = col[4:0] | row[6:0]<<5
//
// col/row take the full 8/7-bit range and are masked per mode, so callers just feed the logical
// tilemap-space coordinate.

module tilemap_addrgen (
	input  logic [1:0] mode,
	input  logic [7:0] col,
	input  logic [6:0] row,
	output logic [11:0] vram_index
);

	always_comb begin
		unique case (mode)
			2'd0: vram_index = {6'd0, col[5:0]} | ({6'd0, row[5:0]} << 6);
			2'd1: vram_index = {5'd0, col[6:0]} | ({5'd0, row[4:0]} << 7);
			2'd2: vram_index = {4'd0, col[7:0]} | ({4'd0, row[3:0]} << 8);
			2'd3: vram_index = {7'd0, col[4:0]} | ({7'd0, row[6:0]} << 5);
		endcase
	end

endmodule
