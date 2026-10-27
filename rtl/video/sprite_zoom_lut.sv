// SPDX-License-Identifier: GPL-3.0-or-later
// Sprite zoom scaling lookup: raw 4-bit zoom field -> (dst_size, dx), the two quantities
// drawgfxzoom_core (src/emu/drawgfxt.ipp:738) needs to render one 16x16 source tile at the
// requested scale. Both axes use the same tile size and formula, each fed its own raw zoom.
//
// dst_size = 16 - (raw>>1) is a plain subtract/shift, computed directly. dx is really
// 1048576/dst_size, which does not reduce, but only 8 values exist, so it is an exact small table
// rather than a divider.
//
// This board has no zoom: raw_zoom is always 0 here, so dst_size is 16 and dx is 1.0.

module sprite_zoom_lut (
	input  logic [3:0]  raw_zoom,
	output logic [4:0]  dst_size,   // 9-16
	output logic [16:0] dx          // 16.16 fixed-point source step per dest pixel
);

	assign dst_size = 5'd16 - {4'd0, raw_zoom[3:1]};

	always_comb begin
		unique case (raw_zoom[3:1])   // dx only depends on raw>>1 (8 distinct values)
			3'd0: dx = 17'h10000;
			3'd1: dx = 17'h11111;
			3'd2: dx = 17'h12492;
			3'd3: dx = 17'h13B13;
			3'd4: dx = 17'h15555;
			3'd5: dx = 17'h1745D;
			3'd6: dx = 17'h19999;
			3'd7: dx = 17'h1C71C;
		endcase
	end

endmodule
