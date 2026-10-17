`timescale 1ns/1ps
// compositor against dreamwld.cpp screen_update's mixing: layer 0 opaque, layer 1 over it on
// any pen but 0, sprites over both; tiles at 0x800 + colour*16 + pen, sprites at colour*16 + pen.
// Exhaustive over the pens and the valid/enable/present bits, at a few colours.
module tb_compositor;
	logic        l0_valid, l1_valid, l0_enable, l1_enable, sp_present;
	logic [3:0]  l0_pixel, l1_pixel, sp_pixel;
	logic [6:0]  l0_color, l1_color;
	logic [5:0]  sp_color;
	logic [11:0] pal_addr;
	logic [9:0]  pal_s_addr;
	logic        sprite_sel, backdrop_black;

	compositor dut (.*);

	int errors = 0, checks = 0;
	initial begin
		for (int c = 0; c < 4; c++) begin
			l0_color = 7'(c * 5);          // layer 0 colours 0-7
			l1_color = 7'(64 + c * 2);     // layer 1 colours carry +0x40
			sp_color = 6'(c * 21);
			for (int bits = 0; bits < 32; bits++) begin
				{l0_valid, l0_enable, l1_valid, l1_enable, sp_present} = 5'(bits);
				for (int p0 = 0; p0 < 16; p0 += 5) for (int p1 = 0; p1 < 16; p1++) for (int ps = 1; ps < 16; ps += 7) begin
					logic l0d, l1d;
					logic [11:0] want;
					l0_pixel = 4'(p0); l1_pixel = 4'(p1); sp_pixel = 4'(ps);
					#1;
					l0d  = l0_valid && l0_enable;
					l1d  = l1_valid && l1_enable && p1 != 0;
					want = l1d ? 12'h800 + {1'b0, l1_color, l1_pixel} : 12'h800 + {1'b0, l0_color, l0_pixel};
					checks++;
					if ((!sp_present && (l1d || l0d) && pal_addr !== want) || sprite_sel !== sp_present
					    || (sp_present && pal_s_addr !== {sp_color, sp_pixel})
					    || backdrop_black !== !(l1d || l0d)) begin
						errors++;
						if (errors <= 5)
							$display("FAIL bits %05b pens %0d/%0d/%0d: pal %03x (want %03x) sel %b black %b s %03x",
							         bits, p0, p1, ps, pal_addr, want, sprite_sel, backdrop_black, pal_s_addr);
					end
				end
			end
		end
		if (errors == 0) $display("PASS: compositor, %0d cases", checks);
		else             $display("FAIL: %0d of %0d cases", errors, checks);
		$finish;
	end
endmodule
