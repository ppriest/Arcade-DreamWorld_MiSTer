`timescale 1ns/1ps
// Flip Screen check for tilemap_line_engine: a flipped screen must be the
// unflipped screen rotated 180 degrees, pixel for pixel. So for every line v,
// what the engine shows on screen COLUMN c with flip=1 on line 223-v must be
// what it shows on column 307-c with flip=0 on line v.
//
// Compared by screen column, not by stream position: a pixel is registered on
// the ce_pix edge that advances hcnt, so it is on screen while hcnt reads one
// more than its column (video_timing: screen x = hcnt - 1). Comparing stream
// order hid a two-column error that came entirely from that one-column delay
// (unflipped it shifts the image one way, flipped the other).
//
// Content is chosen so an error cannot hide: every VRAM cell, every tile row
// and every row-scroll entry differs (hash-derived), the line timing is the
// real video_timing raster at the real 1-in-12 ce_pix, and the sweep covers
// all four tilemap sizes, scroll values with every fine-x residue class the
// cases hit, rowscroll off / per-line / per-tile, and the first, last and
// interior lines -- including a rowscroll value that pushes the source window
// across the tilemap's wrap.
module tb_tilemap_flip;

	logic clk = 0;
	always #5 clk = ~clk;
	logic reset;

	// ---- real raster timing (hcnt / h_active / line_start / ce_pix) ----
	logic [3:0] ce_cnt = 0;
	wire ce_pix = (ce_cnt == 0);
	always_ff @(posedge clk) ce_cnt <= (ce_cnt == 11) ? 4'd0 : ce_cnt + 4'd1;

	logic [8:0] hcnt, vcnt_raw;
	logic [7:0] vcnt_active, vcnt_next_active, vcnt_next2_active;
	logic       h_active, v_active, hblank, vblank, hsync, vsync, line_start, frame_start;
	video_timing u_timing (
		.clk(clk), .ce_pix(ce_pix), .reset(reset),
		.hcnt(hcnt), .vcnt(vcnt_raw), .vcnt_active(vcnt_active),
		.vcnt_next_active(vcnt_next_active), .vcnt_next2_active(vcnt_next2_active),
		.h_active(h_active), .v_active(v_active), .hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync), .line_start(line_start), .frame_start(frame_start)
	);

	// ---- engine under test ----
	logic [7:0]  vcnt;             // the line to render, driven per test
	logic [1:0]  mode;
	logic [15:0] base_x_scroll, base_y_scroll;
	logic [1:0]  bank;
	logic        rowscroll_enable, rowscroll_pertile, flip;
	logic [7:0]  rowscroll_addr;
	logic [15:0] rowscroll_data;
	logic [11:0] vram_addr;
	logic [15:0] vram_data;
	logic        gfxrom_req, gfxrom_valid;
	logic [21:0] gfxrom_addr;
	logic [63:0] gfxrom_data;
	logic        pixel_valid, fetch_overrun, overrun_ev;
	logic [3:0]  pixel_index;
	logic [6:0]  pixel_color;

	tilemap_line_engine #(.LAYER(1)) dut (
		.clk(clk), .reset(reset),
		.vcnt(vcnt), .ce_pix(ce_pix), .h_active(h_active), .line_start(line_start),
		.mode(mode), .base_x_scroll(base_x_scroll), .base_y_scroll(base_y_scroll), .bank(bank),
		.rowscroll_enable(rowscroll_enable), .rowscroll_pertile(rowscroll_pertile), .flip(flip),
		.rowscroll_addr(rowscroll_addr), .rowscroll_data(rowscroll_data),
		.vram_addr(vram_addr), .vram_data(vram_data),
		.gfxrom_req(gfxrom_req), .gfxrom_addr(gfxrom_addr),
		.gfxrom_valid(gfxrom_valid), .gfxrom_data(gfxrom_data),
		.pixel_valid(pixel_valid), .pixel_index(pixel_index), .pixel_color(pixel_color),
		.fetch_overrun(fetch_overrun), .overrun_ev(overrun_ev)
	);

	// ---- memories: 1-cycle synchronous reads, distinct content everywhere ----
	logic [15:0] vram_mem [0:4095];
	logic [15:0] rs_mem   [0:255];
	always_ff @(posedge clk) vram_data      <= vram_mem[vram_addr];
	always_ff @(posedge clk) rowscroll_data <= rs_mem[rowscroll_addr];

	function automatic [31:0] hash(input [31:0] x);
		logic [31:0] h;
		h = x * 32'h9E3779B1;
		h = h ^ (h >> 15);
		h = h * 32'h85EBCA77;
		return h ^ (h >> 13);
	endfunction

	// gfx ROM: row content is a function of the full row address, 4-cycle latency
	int gdelay;
	logic [21:0] gaddr;
	always_ff @(posedge clk) begin
		if (reset) begin
			gfxrom_valid <= 1'b0;
			gdelay <= 0;
		end else begin
			gfxrom_valid <= 1'b0;
			if (gfxrom_req && gdelay == 0) begin
				gdelay <= 4;
				gaddr  <= gfxrom_addr;
			end else if (gdelay > 0) begin
				if (gdelay == 1) begin
					gfxrom_data  <= {hash({10'd0, gaddr}), hash({10'd1, gaddr})};
					gfxrom_valid <= 1'b1;
				end
				gdelay <= gdelay - 1;
			end
		end
	end

	// ---- capture: one sample per displayed pixel ----
	logic ce_d;
	always_ff @(posedge clk) ce_d <= ce_pix;
	logic [10:0] cap [0:307];     // {valid, color, index}
	int ncap;
	logic capturing;
	// overrun events while a test line is on screen (the sticky flag also
	// latches on the first active span after reset, before any prefetch)
	int ovr_events = 0;
	always @(posedge clk) if (capturing && overrun_ev) ovr_events++;

	// cap[c] = what is on the engine outputs while hcnt == c + 1 (screen x c), sampled on
	// the cycle a ce_pix edge would register it downstream
	always @(posedge clk) begin
		if (capturing && ce_pix && hcnt >= 1 && hcnt <= 308) begin
			cap[hcnt - 1] <= {pixel_valid, pixel_color, pixel_index};
			ncap <= ncap + 1;
		end
	end

	// Render one line: set vcnt/flip, wait for line_start, capture 308 pixels.
	task automatic render(input [7:0] line, input logic f, output logic [10:0] out [0:307], output logic ovr);
		@(posedge clk);
		vcnt = line;
		flip = f;
		// synchronise to a line_start, then capture the following active span
		@(posedge clk iff line_start);
		// line_start rises with hcnt already at 309, so wait for the next line
		// to begin before arming the capture
		@(posedge clk iff (hcnt == 9'd0));
		ncap = 0;
		capturing = 1'b1;
		@(posedge clk iff (ncap >= 308));
		capturing = 1'b0;
		for (int p = 0; p < 308; p++) out[p] = cap[p];
		ovr = fetch_overrun;
	endtask

	int errors = 0, lines_checked = 0;
	logic [10:0] a [0:307];
	logic [10:0] b [0:307];
	logic ovr_a, ovr_b;

	task automatic check_config(input string name);
		logic [7:0] lines [0:5];
		lines = '{8'd0, 8'd1, 8'd7, 8'd100, 8'd222, 8'd223};
		for (int i = 0; i < 6; i++) begin
			render(lines[i], 1'b0, a, ovr_a);
			render(8'd223 - lines[i], 1'b1, b, ovr_b);
			for (int p = 0; p < 308; p++) begin
				if (a[p][10] !== 1'b1 || b[307-p] !== a[p]) begin
					errors++;
					if (errors <= 20)
						$display("FAIL %s line %0d col %0d: unflipped {v,c,i}=%h, flipped line %0d col %0d = %h",
						         name, lines[i], p, a[p], 223 - lines[i], 307 - p, b[307-p]);
				end
			end
			lines_checked++;
		end
		if (ovr_events != 0) begin
			errors++;
			$display("FAIL %s: %0d fetch overrun events during capture", name, ovr_events);
			ovr_events = 0;
		end
	endtask

	initial begin
		for (int i = 0; i < 4096; i++) vram_mem[i] = hash(32'h1000 + i);
		for (int i = 0; i < 256;  i++) rs_mem[i]   = hash(32'h2000 + i);
		reset = 1; capturing = 0; ncap = 0;
		mode = 0; base_x_scroll = 0; base_y_scroll = 0; bank = 0;
		rowscroll_enable = 0; rowscroll_pertile = 0; flip = 0; vcnt = 0;
		repeat (20) @(posedge clk);
		reset = 0;

		for (int m = 0; m < 4; m++) begin
			mode = m[1:0];
			bank = m[1:0];
			base_x_scroll = 16'h0123 + 16'(m * 16'h0917);   // fine residues 3, 10, 1, 8
			base_y_scroll = 16'h0045 + 16'(m * 16'h01F3);
			rowscroll_enable = 0; rowscroll_pertile = 0;
			check_config($sformatf("mode%0d norowscroll", m));
			rowscroll_enable = 1; rowscroll_pertile = 0;
			check_config($sformatf("mode%0d per-line rowscroll", m));
			rowscroll_enable = 1; rowscroll_pertile = 1;
			check_config($sformatf("mode%0d per-tile rowscroll", m));
		end
		// scroll values 0 and 0xFFFF: the source window starts exactly on and
		// just before a wrap
		mode = 2'd3; rowscroll_enable = 0; rowscroll_pertile = 0;
		base_x_scroll = 16'h0000; base_y_scroll = 16'h0000;
		check_config("mode3 scroll 0");
		base_x_scroll = 16'hFFFF; base_y_scroll = 16'hFFFF;
		check_config("mode3 scroll FFFF");

		if (errors == 0)
			$display("PASS: flipped output is the 180-degree rotation of unflipped output (%0d line pairs, columns 0-307)", lines_checked);
		else
			$display("FAIL: %0d mismatches over %0d line pairs", errors, lines_checked);
		$finish;
	end

	initial begin
		#2_000_000_000;
		$display("FAIL: watchdog timeout");
		$finish;
	end
endmodule
