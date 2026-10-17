`timescale 1ns/1ps
// A window of MAME's OKI writes replayed through the core's sound block and the real SDRAM path;
// the mixed output recorded once an OKI sample for sim/oki_trace_tb/run.py to compare with
// scripts/oki_trace.py's model of the same writes.
//
// <DIR>/window_events.txt: "clk chip data|bank value", 54 MHz from the window start.
// RUN FROM THE REPOSITORY ROOT, after python scripts/oki_trace.py <set> ... --window START SECONDS:
//     scripts/run_sim.sh oki_trace_tb +DIR=debug/oki_trace/dreamwld_play +IMG=debug/dreamwld-image.sdram +N=18181
// Writes <DIR>/rtl_window.txt: the 16-bit mix, one OKI sample a line, from the window start.
module tb_oki_trace;
	localparam real HALF = 9.2593;      // 54 MHz
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic reset = 1;

	wire  [15:0] SDRAM_DQ;
	logic [12:0] SDRAM_A;
	logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;
	logic [1:0]  SDRAM_BA;

	logic         oki1_req, oki2_req, oki1_valid, oki2_valid;
	logic [19:0] oki1_addr, oki2_addr;
	logic [7:0]  oki1_data, oki2_data;

	dreamworld_sdram_top u_sdram (
		.clk(clk), .reset(reset), .init(1'b0),
		.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),
		.ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(25'd0),
		.ioctl_dout(8'd0), .ioctl_wait(),
		.ldr_active(1'b0), .ldr_req(1'b0), .ldr_addr(25'd0), .ldr_data(16'd0), .ldr_we16(1'b0), .ldr_busy(),
		.l0_gfxrom_req(1'b0), .l0_gfxrom_addr(22'd0), .l0_gfxrom_valid(), .l0_gfxrom_data(),
		.l1_gfxrom_req(1'b0), .l1_gfxrom_addr(22'd0), .l1_gfxrom_valid(), .l1_gfxrom_data(),
		.sp_gfxrom_req(1'b0), .sp_gfxrom_addr(23'd0), .sp_gfxrom_valid(), .sp_gfxrom_data(),
		.sp_lut_req(1'b0), .sp_lut_addr(17'd0), .sp_lut_valid(), .sp_lut_data(),
		.cpu_rom_req(1'b0), .cpu_rom_addr(20'd0), .cpu_rom_valid(), .cpu_rom_data(),
		.oki1_rom_req(oki1_req), .oki1_rom_addr(oki1_addr), .oki1_rom_valid(oki1_valid), .oki1_rom_data(oki1_data),
		.oki2_rom_req(oki2_req), .oki2_rom_addr(oki2_addr), .oki2_rom_valid(oki2_valid), .oki2_rom_data(oki2_data),
		.mcu_rom_we(), .mcu_rom_waddr(), .mcu_rom_wdata(), .mcu_rom_wbe()
	);

	sdram_chip_model_wide u_chip (
		.clk(clk),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	logic       wr1 = 0, wr2 = 0, bwe1 = 0, bwe2 = 0;
	logic [7:0] wdata = 0;
	logic [1:0] bank = 0;
	logic [15:0] audio;

	dreamworld_sound u_snd (
		.clk(clk), .reset(reset), .has_oki2(1'b1),
		.oki1_wr(wr1), .oki2_wr(wr2), .wdata(wdata), .oki1_dout(), .oki2_dout(),
		.oki1_bank_we(bwe1), .oki2_bank_we(bwe2), .bank(bank),
		.oki1_rom_req(oki1_req), .oki1_rom_addr(oki1_addr), .oki1_rom_valid(oki1_valid), .oki1_rom_data(oki1_data),
		.oki2_rom_req(oki2_req), .oki2_rom_addr(oki2_addr), .oki2_rom_valid(oki2_valid), .oki2_rom_data(oki2_data),
		.audio(audio)
	);

	// ---- the window's clock: writes at their clk, samples recorded from clk 0 ----
	longint t = 0;
	logic   running = 0;
	always @(posedge clk) if (running) t <= t + 1;

	int fo, nsamp = 0, nmax = 18181;
	always @(posedge clk) if (running && u_snd.u_oki1.cen_sr && nsamp < nmax) begin
		$fwrite(fo, "%0d\n", $signed(audio));
		nsamp <= nsamp + 1;
	end

	initial begin
		string dir, img, kind;
		int    f, n, fe, chipn, value;
		longint at;
		if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "+DIR missing");
		if (!$value$plusargs("IMG=%s", img)) $fatal(1, "+IMG missing");
		void'($value$plusargs("N=%d", nmax));
		f = $fopen(img, "rb");
		if (f == 0) $fatal(1, "cannot open %s", img);
		n = $fread(u_chip.mem, f);
		$fclose(f);
		fe = $fopen({dir, "/window_events.txt"}, "r");
		if (fe == 0) $fatal(1, "cannot open %s/window_events.txt", dir);
		fo = $fopen({dir, "/rtl_window.txt"}, "w");

		repeat (20) @(posedge clk);
		reset = 0;
		repeat (2000) @(posedge clk);           // sdram.sv's power-up sequence
		@(negedge clk);
		running = 1;
		while ($fscanf(fe, "%d %d %s %d\n", at, chipn, kind, value) == 4) begin
			while (t < at) @(negedge clk);
			if (kind == "bank") begin
				bank = 2'(value); bwe1 = (chipn == 1); bwe2 = (chipn == 2);
			end else begin
				wdata = 8'(value); wr1 = (chipn == 1); wr2 = (chipn == 2);
			end
			@(negedge clk);
			{wr1, wr2, bwe1, bwe2} = 4'b0000;
		end
		$fclose(fe);
		wait (nsamp >= nmax);
		$fclose(fo);
		$display("%0d samples recorded to %s/rtl_window.txt", nsamp, dir);
		$finish;
	end
endmodule
