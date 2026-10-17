`timescale 1ns/1ps
// Integration test for rtl/memory/dreamworld_sdram_top.sv: every sub-piece
// (sdram.sv, sdram_phy.sv, the arbiters, sdram_narrow_bridge.sv,
// gfxrom_byte_reorder.sv, sdram_download.sv) has its own bench -- this
// test's job is only to prove THIS module's wiring: each client port's
// fixed region base offset and word->byte address conversion is correct,
// and gfx-ROM clients see byte-reordered data while narrow clients don't.
//
// Uses the real HPS download path (sdram_download.sv) to seed known,
// distinctive byte patterns at each region's base address, then issues a
// real read on each client port and checks the expected value
// lands -- proves the whole chain (client req -> this module's address
// arithmetic -> sdram_phy/arbiters -> sdram.sv -> real chip model ->
// back out, reordered where required) for every region in one pass.
module tb_dreamworld_sdram_top;

	logic clk = 0;
	always #5 clk = ~clk;
	logic reset;

	localparam logic [24:0] MAINCPU_BASE   = 25'h0000000;
	localparam logic [24:0] SPRITES_BASE   = 25'h0200000;
	localparam logic [24:0] TILES_BASE      = 25'h0A00000;
	localparam logic [24:0] SPRITELUT_BASE = 25'h0C00000;
	localparam logic [24:0] MCU_BASE       = 25'h0D40000;

	logic        mcu_we;
	logic [11:0] mcu_waddr;
	logic [15:0] mcu_wdata;
	logic [1:0]  mcu_wbe;
	// the MCU ROM tap's writes, in order
	logic [29:0] mcu_log [0:7];
	int          mcu_n = 0;
	always @(posedge clk) if (mcu_we && mcu_n < 8) begin mcu_log[mcu_n] = {mcu_waddr, mcu_wdata, mcu_wbe}; mcu_n++; end

	logic         ioctl_download;
	logic [15:0] ioctl_index;
	logic         ioctl_wr;
	logic [24:0] ioctl_addr;
	logic [7:0]  ioctl_dout;
	logic         ioctl_wait;

	logic         l0_gfxrom_req, l1_gfxrom_req;
	logic [21:0] l0_gfxrom_addr, l1_gfxrom_addr;
	logic         l0_gfxrom_valid, l1_gfxrom_valid;
	logic [63:0] l0_gfxrom_data, l1_gfxrom_data;

	logic         sp_gfxrom_req, sp_lut_req;
	logic [22:0] sp_gfxrom_addr;
	logic [16:0] sp_lut_addr;
	logic         sp_gfxrom_valid, sp_lut_valid;
	logic [63:0] sp_gfxrom_data;
	logic [15:0] sp_lut_data;

	logic         cpu_rom_req;
	logic [19:0] cpu_rom_addr;
	logic         cpu_rom_valid;
	logic [15:0] cpu_rom_data;


	wire [15:0] SDRAM_DQ;
	logic [12:0] SDRAM_A;
	logic         SDRAM_DQML, SDRAM_DQMH;
	logic [1:0]  SDRAM_BA;
	logic         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;

	dreamworld_sdram_top dut (
		.clk(clk), .reset(reset), .init(1'b0),
		.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_wait(ioctl_wait),
		// fast ROM loader idle: this TB downloads through ioctl
		.ldr_active(1'b0), .ldr_req(1'b0), .ldr_addr(25'd0), .ldr_data(16'd0),
		.ldr_we16(1'b0), .ldr_busy(),
		.l0_gfxrom_req(l0_gfxrom_req), .l0_gfxrom_addr(l0_gfxrom_addr),
		.l0_gfxrom_valid(l0_gfxrom_valid), .l0_gfxrom_data(l0_gfxrom_data),
		.l1_gfxrom_req(l1_gfxrom_req), .l1_gfxrom_addr(l1_gfxrom_addr),
		.l1_gfxrom_valid(l1_gfxrom_valid), .l1_gfxrom_data(l1_gfxrom_data),
		.sp_gfxrom_req(sp_gfxrom_req), .sp_gfxrom_addr(sp_gfxrom_addr),
		.sp_gfxrom_valid(sp_gfxrom_valid), .sp_gfxrom_data(sp_gfxrom_data),
		.sp_lut_req(sp_lut_req), .sp_lut_addr(sp_lut_addr),
		.sp_lut_valid(sp_lut_valid), .sp_lut_data(sp_lut_data),
		.cpu_rom_req(cpu_rom_req), .cpu_rom_addr(cpu_rom_addr),
		.cpu_rom_valid(cpu_rom_valid), .cpu_rom_data(cpu_rom_data),
		.mcu_rom_we(mcu_we), .mcu_rom_waddr(mcu_waddr), .mcu_rom_wdata(mcu_wdata), .mcu_rom_wbe(mcu_wbe)
	);

	sdram_chip_model chip (
		.clk(clk),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	int errors = 0;

	// Pulse ioctl_wr for one cycle, then wait for ioctl_wait to drop --
	// matches sim/ddram_download_tb/tb_ddram_download.sv's already-proven
	// send_byte task exactly, including the do/while (not while/do): a
	// plain `while (ioctl_wait) @(posedge clk);` checks ioctl_wait
	// immediately after clearing ioctl_wr, in the same active-region delta
	// as the DUT's own always_ff updating dstate for that same edge --
	// NBA updates haven't committed yet, so that first check can read a
	// stale, pre-transition ioctl_wait and return before the real
	// transaction even starts, silently dropping every other byte in a
	// back-to-back sequence (found the hard way: half of every 8-byte
	// write pattern below came back X on first run). do/while guarantees
	// at least one full edge elapses -- and NBA updates settle -- before
	// ioctl_wait is ever read.
	// sdram_download coalesces byte pairs into single word writes, so a
	// lone EVEN byte stays buffered until its odd partner arrives or the
	// download ends. Tests that write one byte and read it straight back
	// call dl_flush(), which drops ioctl_download exactly as the HPS does
	// at the end of a transfer -- exercising the DUT's real flush path.
	task automatic dl_write_byte(input [24:0] addr, input [7:0] data);
		@(posedge clk);
		ioctl_addr = addr; ioctl_dout = data; ioctl_wr = 1'b1;
		@(posedge clk);
		ioctl_wr = 1'b0;
		do @(posedge clk); while (ioctl_wait);
	endtask

	task automatic dl_flush();
		ioctl_download = 1'b0;
		repeat (2) @(posedge clk);
		do @(posedge clk); while (ioctl_wait);
		ioctl_download = 1'b1;
		@(posedge clk);
	endtask

	task automatic check64(input [63:0] got, input [63:0] exp, input string name);
		if (got !== exp) begin
			errors++;
			$display("FAIL %s: got=%h expected=%h", name, got, exp);
		end
	endtask

	task automatic check16(input [15:0] got, input [15:0] exp, input string name);
		if (got !== exp) begin
			errors++;
			$display("FAIL %s: got=%h expected=%h", name, got, exp);
		end
	endtask

	task automatic check8(input [7:0] got, input [7:0] exp, input string name);
		if (got !== exp) begin
			errors++;
			$display("FAIL %s: got=%h expected=%h", name, got, exp);
		end
	endtask

	initial begin
		reset = 1;
		ioctl_download = 0; ioctl_index = 0; ioctl_wr = 0; ioctl_addr = 0; ioctl_dout = 0;
		l0_gfxrom_req = 0; l0_gfxrom_addr = 0;
		l1_gfxrom_req = 0; l1_gfxrom_addr = 0;
		sp_gfxrom_req = 0; sp_gfxrom_addr = 0;
		sp_lut_req = 0; sp_lut_addr = 0;
		cpu_rom_req = 0; cpu_rom_addr = 0;
		repeat (5) @(posedge clk);
		reset = 0;
		repeat (5) @(posedge clk);

		// Each region is written via the real HPS download path and read
		// back through its own client port IMMEDIATELY, one region at a
		// time, rather than seeding everything up front -- sim/sdram_tb/
		// sdram_chip_model.sv deliberately folds the row address to its
		// low 8 bits (its own header comment: sized for what testbenches
		// actually exercise, not full 32MB chip capacity), so two of this
		// project's real region bases (spanning several MB apart) can
		// alias to the same modeled storage if both are live at once. Not
		// a bug in dreamworld_sdram_top.sv's own address arithmetic (confirmed
		// by exactly this per-region isolation passing cleanly below) --
		// just a shared-testbench-model limitation this test structure
		// sidesteps rather than works around by widening the shared model
		// for one test's sake.
		ioctl_download = 1;

		for (int i = 0; i < 8; i++) dl_write_byte(TILES_BASE + i[24:0], i[7:0]);
		dl_flush();
		l0_gfxrom_addr = 22'd0; l0_gfxrom_req = 1;
		@(posedge clk);
		while (!l0_gfxrom_valid) @(posedge clk);
		check64(l0_gfxrom_data, 64'h0001020304050607, "l0_gfxrom_data");
		l0_gfxrom_req = 0;

		// layer 1 reads the SAME shared tiles region, same content still resident.
		l1_gfxrom_addr = 22'd0; l1_gfxrom_req = 1;
		@(posedge clk);
		while (!l1_gfxrom_valid) @(posedge clk);
		check64(l1_gfxrom_data, 64'h0001020304050607, "l1_gfxrom_data");
		l1_gfxrom_req = 0;

		// Concurrent stress test for sdram_arbiter2 (Port 0), added
		// 2026-08-29 after live hardware reported tilemap corruption
		// alongside the confirmed sprite Port 1 bug. Both layers now share
		// ONE physical port through this arbiter (they had one dedicated
		// port each before the re-partition) -- the sequential checks above
		// never exercise the round-robin picker or c0_data/c1_data (both
		// wired to the SAME phy_rdata bus, gated only by c0_valid/c1_valid)
		// under real contention. This asserts both requests on the SAME
		// cycle, for two DIFFERENT addresses/patterns, and checks each
		// layer gets its OWN data back regardless of which the arbiter
		// serves first -- would catch cross-talk (one layer latching the
		// other's data) or a starved/dropped grant that the sequential
		// checks structurally cannot.
		for (int i = 0; i < 8; i++) dl_write_byte(TILES_BASE + 25'd16 + i[24:0], (8'h30 + i[7:0]));
		for (int i = 0; i < 8; i++) dl_write_byte(TILES_BASE + 25'd24 + i[24:0], (8'h40 + i[7:0]));
		dl_flush();
		l0_gfxrom_addr = 22'd16; l1_gfxrom_addr = 22'd24;
		l0_gfxrom_req  = 1;      l1_gfxrom_req  = 1;
		fork
			begin
				while (!l0_gfxrom_valid) @(posedge clk);
				check64(l0_gfxrom_data, 64'h3031323334353637, "l0_gfxrom_data (concurrent w/ l1)");
				l0_gfxrom_req = 0;
			end
			begin
				while (!l1_gfxrom_valid) @(posedge clk);
				check64(l1_gfxrom_data, 64'h4041424344454647, "l1_gfxrom_data (concurrent w/ l0)");
				l1_gfxrom_req = 0;
			end
		join
		@(posedge clk);

		for (int i = 0; i < 8; i++) dl_write_byte(SPRITES_BASE + i[24:0], (8'h10 + i));
		dl_flush();
		sp_gfxrom_addr = 23'd0; sp_gfxrom_req = 1;
		@(posedge clk);
		while (!sp_gfxrom_valid) @(posedge clk);
		check64(sp_gfxrom_data, 64'h1011121314151617, "sp_gfxrom_data");
		sp_gfxrom_req = 0;

		// Regression for the 2026-08-29 spurious-re-request bug (confirmed
		// live on hardware: corrupted/wobbly sprites, worse sp_render_max).
		// The check above clears sp_gfxrom_req in the SAME simulation delta
		// it observes valid -- that does NOT reproduce the real consumer's
		// timing. sprite_render_engine.sv's own always_ff needs a full extra
		// clock edge just to SEE gfxrom_valid (ordinary register-to-register
		// latency: it can only react to the value gfxrom_valid held during
		// the PREVIOUS cycle), and only THEN schedules gfxrom_req<=0 -- so
		// in real hardware, gfxrom_req is still asserted going into the very
		// edge where sdram_phy (back in S_IDLE) samples req again. An
		// immediate same-delta clear here never gives the DUT that window.
		// Reproduce it explicitly: hold req for one MORE full clock past the
		// edge that first shows valid before clearing it, then immediately
		// ask for a different granule the way the real engine's next-row
		// fetch would -- if a spurious transaction snuck into that window,
		// this either hangs (the real request gets silently dropped because
		// the bogus transaction still owns the port) or comes back with the
		// wrong granule's data.
		for (int i = 0; i < 8; i++) dl_write_byte(SPRITES_BASE + 25'd8 + i[24:0], (8'h20 + i[7:0]));
		sp_gfxrom_addr = 23'd0; sp_gfxrom_req = 1;
		@(posedge clk);
		while (!sp_gfxrom_valid) @(posedge clk);
		check64(sp_gfxrom_data, 64'h1011121314151617, "sp_gfxrom_data (held-req regression, granule 0)");
		@(posedge clk);   // the extra cycle real hardware gets for free
		sp_gfxrom_req = 0;
		sp_gfxrom_addr = 23'd8;
		sp_gfxrom_req = 1;
		@(posedge clk);
		while (!sp_gfxrom_valid) @(posedge clk);
		check64(sp_gfxrom_data, 64'h2021222324252627, "sp_gfxrom_data (held-req regression, granule 1)");
		sp_gfxrom_req = 0;

		dl_write_byte(SPRITELUT_BASE + 25'd0, 8'hAA);
		dl_write_byte(SPRITELUT_BASE + 25'd1, 8'hBB);
		dl_flush();
		sp_lut_addr = 17'd0; sp_lut_req = 1;
		@(posedge clk);
		while (!sp_lut_valid) @(posedge clk);
		check16(sp_lut_data, 16'hBBAA, "sp_lut_data"); // little-endian word: byte0=low, byte1=high
		sp_lut_req = 0;

		dl_write_byte(MAINCPU_BASE + 25'd0, 8'hCC);
		dl_write_byte(MAINCPU_BASE + 25'd1, 8'hDD);
		dl_flush();
		cpu_rom_addr = 19'd0; cpu_rom_req = 1;
		@(posedge clk);
		while (!cpu_rom_valid) @(posedge clk);
		// Big-endian: byte0 (lower address) is the word's HIGH byte --
		// maincpu's real 68020 program ROM convention, NOT
		// sdram_narrow_bridge.sv's own little-endian packing (correct for
		// spritelut's ROM_REGION16_LE content, wrong for maincpu's plain
		// ROM_REGION content) -- see dreamworld_sdram_top.sv's u_cpu_bridge
		// comment for the real bug this was found fixing.
		check16(cpu_rom_data, 16'hCCDD, "cpu_rom_data");
		cpu_rom_req = 0;

		// MCU ROM tap: a byte pair is one word write (even byte low), a lone odd byte goes
		// to the upper lane; bytes outside the 8 KB window are not tapped.
		dl_write_byte(MCU_BASE + 25'd0, 8'h02);
		dl_write_byte(MCU_BASE + 25'd1, 8'h00);
		dl_write_byte(MCU_BASE + 25'd5, 8'h75);
		dl_flush();
		dl_write_byte(MCU_BASE + 25'h2000, 8'h11);
		dl_flush();
		if (mcu_n !== 2) begin errors++; $display("FAIL mcu tap: %0d writes, expected 2", mcu_n); end
		else begin
			if (mcu_log[0] !== {12'd0, 16'h0002, 2'b11}) begin errors++; $display("FAIL mcu tap word: %h", mcu_log[0]); end
			if (mcu_log[1] !== {12'd2, 16'h7575, 2'b10}) begin errors++; $display("FAIL mcu tap byte: %h", mcu_log[1]); end
		end

		ioctl_download = 0;

		if (errors == 0) $display("ALL TESTS PASSED");
		else $display("%0d TEST(S) FAILED", errors);

		$finish;
	end

	initial begin
		#4_000_000; // watchdog
		$display("FAIL: watchdog timeout, simulation did not finish");
		$finish;
	end

endmodule
