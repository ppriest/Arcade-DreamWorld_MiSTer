`timescale 1ns/1ps
// spriteram_dbuf: the CPU's RAM is copied, words 0-2047, into the snapshot on copy_start;
// copy_busy covers the copy; writes after the copy do not reach the snapshot until the next.
module tb_spriteram_dbuf;
	logic clk = 0;
	always #5 clk = ~clk;
	logic        reset = 1, copy_start = 0, copy_busy;
	logic [11:0] cpu_addr = 0, at_addr = 0;
	logic        cpu_wel = 0, cpu_weh = 0;
	logic [15:0] cpu_wdata = 0, cpu_rdata, at_data;

	spriteram_dbuf dut (.*);

	int errors = 0, busy_clks = 0;

	task automatic fill(input logic [15:0] salt);
		for (int i = 0; i < 4096; i++) begin
			@(negedge clk); cpu_addr = 12'(i); cpu_wdata = 16'(i) ^ salt; cpu_wel = 1; cpu_weh = 1;
		end
		@(negedge clk); cpu_wel = 0; cpu_weh = 0;
	endtask

	task automatic copy();
		@(negedge clk); copy_start = 1;
		@(negedge clk); copy_start = 0;
		busy_clks = 1;
		while (copy_busy) begin @(negedge clk); busy_clks++; end
	endtask

	task automatic check(input logic [15:0] salt, input string what);
		int bad = 0;
		for (int i = 0; i < 2048; i++) begin
			@(negedge clk); at_addr = 12'(i);
			@(negedge clk);
			if (at_data !== (16'(i) ^ salt)) bad++;
		end
		if (bad) begin errors++; $display("FAIL %s: %0d of 2048 words wrong", what, bad); end
	endtask

	initial begin
		repeat (3) @(posedge clk);
		reset = 0;
		fill(16'hA5A5);
		copy();
		if (busy_clks < 2048 || busy_clks > 2052) begin errors++; $display("FAIL copy_busy for %0d clk", busy_clks); end
		check(16'hA5A5, "first copy");
		fill(16'h5A00);
		check(16'hA5A5, "snapshot held across CPU writes");
		copy();
		check(16'h5A00, "second copy");
		if (errors == 0) $display("PASS: spriteram_dbuf (copy of 2048 words in %0d clk, held between copies)", busy_clks);
		else             $display("FAIL: %0d", errors);
		$finish;
	end
endmodule
