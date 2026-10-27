// SPDX-License-Identifier: GPL-3.0-or-later
// Converts an effective pixel position (screen position + scroll, already summed by the caller)
// into tile-grid coordinates for tilemap_addrgen plus the fine sub-tile offset, wrapping per the
// current size mode.
//
// Every mode's pixel dimensions are powers of two, so wraparound is a mask before splitting into
// tile index (>>4) and fine offset (&0xF), with no modulo hardware. Only modes 0 and 1 are
// reachable on this board (see tilemap_addrgen). Output widths match tilemap_addrgen's
// col[7:0]/row[6:0]; the masked upper bits per mode come out 0.

module tilemap_coord (
	input  logic [1:0]  mode,
	input  logic [15:0] eff_x,
	input  logic [15:0] eff_y,
	output logic [7:0]  tile_col,
	output logic [6:0]  tile_row,
	output logic [3:0]  fine_x,
	output logic [3:0]  fine_y
);

	logic [15:0] masked_x, masked_y;

	always_comb begin
		unique case (mode)
			2'd0: begin masked_x = eff_x & 16'h03FF; masked_y = eff_y & 16'h03FF; end // 1024x1024
			2'd1: begin masked_x = eff_x & 16'h07FF; masked_y = eff_y & 16'h01FF; end // 2048x512
			2'd2: begin masked_x = eff_x & 16'h0FFF; masked_y = eff_y & 16'h00FF; end // 4096x256
			2'd3: begin masked_x = eff_x & 16'h01FF; masked_y = eff_y & 16'h07FF; end // 512x2048
		endcase
	end

	assign tile_col = masked_x[11:4];
	assign tile_row = masked_y[10:4];
	assign fine_x   = masked_x[3:0];
	assign fine_y   = masked_y[3:0];

endmodule
