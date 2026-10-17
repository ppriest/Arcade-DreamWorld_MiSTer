`timescale 1ns/1ps
// sprite_record_decode against draw_sprites (dreamwld.cpp 203-260). The fields are checked
// directly; the position, exhaustively over x and y, by drawing a sprite of every size both
// ways into a screen mask -- MAME's four copies at X = ((x + 4) & 0x1ff) - 16 and Y = y, with
// -0x200 wraps, against the decode's single signed position -- and requiring the masks equal.
module tb_sprite_record_decode;
	logic [15:0] word_y, word_x, word_attr, word_code_lo;
	logic [3:0]  zoom_y_raw, zoom_x_raw, ny, nx;
	logic signed [9:0] y_pos, x_pos;
	logic        flip_y, flip_x;
	logic [5:0]  color;
	logic [16:0] code;

	sprite_record_decode dut (.*);

	int errors = 0;

	// does a span [a, a + len) touch [0, lim)?
	function automatic bit hits(int a, int len, int lim);
		return (a < lim) && (a + len > 0);
	endfunction

	initial begin
		// fields
		word_y = 16'h0000; word_x = 16'h0000;
		word_attr = 16'hC000 | (6'h2A << 8) | 16'h0001; word_code_lo = 16'h1234;
		#1;
		if (!(flip_y && flip_x && color == 6'h2A && code == 17'h11234 && zoom_x_raw == 0 && zoom_y_raw == 0)) begin
			errors++; $display("FAIL fields: fy %b fx %b colour %h code %h", flip_y, flip_x, color, code);
		end
		word_attr = 16'h0000; word_code_lo = 16'hFFFF;
		#1;
		if (flip_y || flip_x || color != 0 || code != 17'h0FFFF) begin errors++; $display("FAIL fields (clear)"); end

		// sizes and positions: each axis on its own (they are independent)
		for (int sz = 0; sz < 8; sz++) begin
			for (int v = 0; v < 512; v++) begin
				int  mame_x, rtl_x;
				bit  mame_vis, rtl_vis;
				word_x = 16'((sz << 9) | v);
				word_y = 16'((sz << 9) | v);
				#1;
				if (nx != sz + 1 || ny != sz + 1) begin errors++; $display("FAIL size %0d: nx %0d ny %0d", sz, nx, ny); end
				// X: 308 columns, width 16*(sz+1); both flips cover the same columns
				mame_x   = ((v + 4) & 511) - 16;
				mame_vis = hits(mame_x, 16 * (sz + 1), 308) || hits(mame_x - 512, 16 * (sz + 1), 308);
				rtl_vis  = hits(int'(x_pos), 16 * (sz + 1), 308);
				if (mame_vis != rtl_vis || (rtl_vis && hits(mame_x, 16 * (sz + 1), 308) && x_pos != mame_x)
				    || (rtl_vis && !hits(mame_x, 16 * (sz + 1), 308) && x_pos != mame_x - 512)) begin
					errors++;
					if (errors <= 8) $display("FAIL x %0d size %0d: MAME at %0d visible %b, RTL at %0d visible %b",
					                          v, sz, mame_x, mame_vis, x_pos, rtl_vis);
				end
				// Y: 224 lines
				mame_vis = hits(v, 16 * (sz + 1), 224) || hits(v - 512, 16 * (sz + 1), 224);
				rtl_vis  = hits(int'(y_pos), 16 * (sz + 1), 224);
				if (mame_vis != rtl_vis || (rtl_vis && y_pos != (hits(v, 16 * (sz + 1), 224) ? v : v - 512))) begin
					errors++;
					if (errors <= 8) $display("FAIL y %0d size %0d: RTL at %0d visible %b", v, sz, y_pos, rtl_vis);
				end
			end
		end
		if (errors == 0) $display("PASS: sprite_record_decode, fields and every x/y at every size");
		else             $display("FAIL: %0d", errors);
		$finish;
	end
endmodule
