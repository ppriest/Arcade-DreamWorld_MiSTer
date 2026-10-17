`timescale 1ns/1ps
// video_timing over two whole frames, every pixel: 444 x 263; the engines' window h_active at
// hcnt 0-307 and the output's (hblank low) at 1-308; hsync 331-362; vblank from line 224,
// vsync 228-230; line_start once a line, as hcnt goes 308 -> 309; frame_start once a frame, as
// vblank rises; vcnt_next/next2 wrapped on 263; nothing moves without ce_pix (every 3rd clk).
module tb_video_timing;
	logic clk = 0;
	always #5 clk = ~clk;

	logic       reset = 1, ce_pix = 0;
	logic [8:0] hcnt, vcnt;
	logic [7:0] vcnt_active, vcnt_next_active, vcnt_next2_active;
	logic       h_active, v_active, hblank, vblank, hsync, vsync, line_start, frame_start;

	video_timing dut (.*);

	int ce_div = 0;
	always_ff @(posedge clk) begin
		ce_div <= (ce_div == 2) ? 0 : ce_div + 1;
		ce_pix <= (ce_div == 2);
	end

	int errors = 0, lines = 0, frames = 0, n = 0;
	logic [8:0] h_prev = 9'd0;
	logic       ce_prev = 1'b0;

	task automatic fail(input string what);
		errors++;
		if (errors <= 10) $display("FAIL %s at h %0d v %0d", what, hcnt, vcnt);
	endtask

	always @(posedge clk) if (!reset) begin
		// hcnt is seen changed the clk after a ce_pix
		if (!ce_prev && hcnt !== h_prev) fail("hcnt moved without ce_pix");
		h_prev  <= hcnt;
		ce_prev <= ce_pix;
		if (h_active !== (hcnt < 308))                     fail("h_active");
		if (hblank   !== (hcnt == 0 || hcnt > 308))         fail("hblank");
		if (hsync    !== (hcnt >= 331 && hcnt < 363))       fail("hsync");
		if (vblank   !== (vcnt >= 224))                     fail("vblank");
		if (vsync    !== (vcnt >= 228 && vcnt < 231))       fail("vsync");
		if (vcnt_next_active  !== 8'((vcnt + 1) % 263))     fail("vcnt_next_active");
		if (vcnt_next2_active !== 8'((vcnt + 2) % 263))     fail("vcnt_next2_active");
		if (line_start) begin
			lines++;
			if (hcnt !== 9'd309) fail("line_start not at the start of hcnt 309");
		end
		if (frame_start) begin
			frames++;
			if (vcnt !== 9'd224 || hcnt !== 9'd1) fail("frame_start not as vblank rises");
		end
		if (ce_pix && hcnt == 443 && vcnt == 262) n++;
	end

	initial begin
		repeat (5) @(posedge clk);
		reset = 0;
		wait (n == 2);
		@(posedge clk);
		if (lines != 2 * 263) begin errors++; $display("FAIL %0d line_start pulses in two frames", lines); end
		if (frames != 2)      begin errors++; $display("FAIL %0d frame_start pulses in two frames", frames); end
		if (errors == 0) $display("PASS: video_timing, two frames of 444 x 263");
		else             $display("FAIL: %0d", errors);
		$finish;
	end
endmodule
