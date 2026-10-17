`timescale 1ns/1ps
// Row-scroll indexing for tilemap_line_engine, against dreamwld.cpp screen_update:
//
// 1. WHICH ENTRY a line uses:
//        for (i = 0; i < 256; i++)
//            x0 = linebase[((i + 32) & 0xff) >> tile_rowscroll];
//            set_scrollx((i + scrolly) & row_mask, scrollx + x0);
//    so screen line i takes entry (i + 32) & 0xff, or that >> 4 per tile row. The engine
//    reads a 1-cycle synchronous RAM, so the entry is valid two cycles after the address
//    is registered; a stale read shows as a line carrying its predecessor's entry.
//
// 2. WHEN row-scroll is active: on either control bit (layer_ctrl & 0x0300), bit 9
//    selecting per-tile rows. Bit 9 alone is a valid per-tile mode, not "disabled".
//
// The observable is the engine's latched fetch_eff_x: with base_x_scroll 0 and table entry
// v, fetch_eff_x == v & ~15. Entries are multiples of 16 here, so fetch_eff_x reads back the
// entry that was used.
module tb_tilemap_rowscroll;

	logic clk = 0;
	always #5 clk = ~clk;
	logic reset;

	logic [7:0] vcnt;
	logic       ce_pix, h_active, line_start;
	logic [1:0] mode, bank;
	logic [15:0] base_x_scroll, base_y_scroll;
	logic        rowscroll_enable, rowscroll_pertile;
	logic [7:0]  rowscroll_addr;
	logic [15:0] rowscroll_data;
	logic [11:0] vram_addr;
	logic [15:0] vram_data;
	logic        gfxrom_req;
	logic [21:0] gfxrom_addr;
	logic        gfxrom_valid;
	logic [63:0] gfxrom_data;
	logic        pixel_valid, fetch_overrun;
	logic [3:0]  pixel_index;
	logic [6:0]  pixel_color;

	assign ce_pix = 1'b1;

	// Row-scroll table: entry i = i*16, so the entry in use is readable
	// directly off fetch_eff_x. Modelled with the SAME 1-cycle registered
	// read as rtl/memory/dpram.sv port B, which is the whole point.
	logic [15:0] rowscroll_mem [0:255];
	always_ff @(posedge clk) rowscroll_data <= rowscroll_mem[rowscroll_addr];

	// VRAM/gfx ROM are not under test here; keep them quiet and valid.
	logic [15:0] vram_mem [0:4095];
	always_ff @(posedge clk) vram_data <= vram_mem[vram_addr];
	always_ff @(posedge clk) gfxrom_valid <= gfxrom_req;
	assign gfxrom_data = 64'h0123_4567_89AB_CDEF;

	tilemap_line_engine dut (
		.clk(clk), .reset(reset),
		.vcnt(vcnt), .ce_pix(ce_pix), .h_active(h_active), .line_start(line_start),
		.mode(mode), .base_x_scroll(base_x_scroll), .base_y_scroll(base_y_scroll),
		.bank(bank),
		.rowscroll_enable(rowscroll_enable), .rowscroll_pertile(rowscroll_pertile), .flip(1'b0),
		.rowscroll_addr(rowscroll_addr), .rowscroll_data(rowscroll_data),
		.vram_addr(vram_addr), .vram_data(vram_data),
		.gfxrom_req(gfxrom_req), .gfxrom_addr(gfxrom_addr),
		.gfxrom_valid(gfxrom_valid), .gfxrom_data(gfxrom_data),
		.pixel_valid(pixel_valid), .pixel_index(pixel_index),
		.pixel_color(pixel_color), .fetch_overrun(fetch_overrun)
	);

	int errors = 0;

	// Start a line the way video_timing does and return once the engine has
	// latched its per-line scroll, then report the entry it actually used.
	task automatic run_line(input [7:0] line, output [15:0] used_entry);
		vcnt = line;
		@(posedge clk);
		line_start = 1'b1;
		@(posedge clk);
		line_start = 1'b0;
		// Address registers on this edge, RAM data lands one edge later;
		// allow both plus the state that consumes it.
		repeat (4) @(posedge clk);
		used_entry = dut.fetch_eff_x;
	endtask

	task automatic check(input [15:0] got, input [15:0] exp, input string name);
		if (got !== exp) begin
			errors++;
			$display("FAIL %s: engine used entry %0d, expected %0d", name, got, exp);
		end
	endtask

	initial begin
		logic [15:0] used;

		for (int i = 0; i < 256; i++) rowscroll_mem[i] = 16'(i * 16);
		for (int i = 0; i < 4096; i++) vram_mem[i] = 16'h0000;

		reset = 1;
		mode = 2'd0; bank = 2'd0;
		base_x_scroll = 16'd0; base_y_scroll = 16'd0;
		rowscroll_enable = 1'b1; rowscroll_pertile = 1'b0;
		vcnt = 8'd0; h_active = 1'b0; line_start = 1'b0;
		repeat (4) @(posedge clk);
		reset = 0;
		repeat (4) @(posedge clk);

		// ---- per-line row-scroll: line N uses entry (N + 32) & 0xff ----
		// Consecutive lines, as a real frame drives them.
		foreach_line: begin
			for (int n = 1; n <= 6; n++) begin
				run_line(8'(n), used);
				check(used, 16'(((n + 32) & 255) * 16), $sformatf("per-line entry (vcnt=%0d)", n));
			end
		end

		// A non-adjacent jump: distinguishes "off by one" from "always the
		// previously addressed entry, whatever it was".
		run_line(8'd100, used);
		check(used, 16'(132 * 16), "per-line entry (vcnt=100 after jump)");
		run_line(8'd223, used);   // the last line: entry 255
		check(used, 16'(255 * 16), "per-line entry (vcnt=223)");

		// ---- per-tile row-scroll: line N uses entry ((N + 32) & 0xff) >> 4 ----
		rowscroll_pertile = 1'b1;
		run_line(8'd35, used);   // 67 >> 4 = 4
		check(used, 16'(4 * 16), "per-tile entry (vcnt=35 -> index 4)");
		run_line(8'd80, used);   // 112 >> 4 = 7
		check(used, 16'(7 * 16), "per-tile entry (vcnt=80 -> index 7)");
		run_line(8'd223, used);  // 255 >> 4 = 15
		check(used, 16'(15 * 16), "per-tile entry (vcnt=223 -> index 15)");
		rowscroll_pertile = 1'b0;

		// ---- disabled: no row-scroll contribution at all ----
		rowscroll_enable = 1'b0;
		run_line(8'd7, used);
		check(used, 16'd0, "row-scroll disabled (vcnt=7)");
		rowscroll_enable = 1'b1;

		if (errors == 0) $display("ALL TESTS PASSED");
		else             $display("%0d TEST(S) FAILED", errors);
		$finish;
	end

	initial begin
		#200_000;
		$display("FAIL: watchdog timeout");
		$finish;
	end

endmodule
