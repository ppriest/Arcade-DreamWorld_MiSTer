`timescale 1ns/1ps
// OKI phrases through the core's sound block and the real SDRAM path, for
// sim/oki_phrase_tb/run.py to compare with scripts/oki_model.py (MAME's decoder).
//
// dreamworld_sound (both jt6295, their bank registers, the ROM bridges) on dreamworld_sdram_top
// (sample caches on Port 2's c0/c4, the bank mapping, sdram.sv) and the chip model holding the
// set's image. Each case in <DIR>/cases.txt ("chip phrase att bank count"): set the bank, start
// the phrase on voice 0 with the attenuation, record `count` samples of that chip's output at
// its own sample rate (jt6295 cen_sr) from the start command, stop the voice, wait.
//
// RUN FROM THE REPOSITORY ROOT, after python sim/oki_phrase_tb/run.py --prep:
//     scripts/run_sim.sh oki_phrase_tb +DIR=debug/oki_phrase/dreamwld +IMG=debug/dreamwld-image.sdram
// Writes <DIR>/rtl.txt: "case n" then one sample a line.
module tb_oki_phrase;
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

	task automatic write(input int chip, input logic [7:0] d);
		@(negedge clk); wdata = d; wr1 = (chip == 1); wr2 = (chip == 2);
		@(negedge clk); wr1 = 0; wr2 = 0;
		repeat (60) @(negedge clk);    // the 68020 is far slower than this
	endtask

	task automatic set_bank(input int chip, input logic [1:0] b);
		@(negedge clk); bank = b; bwe1 = (chip == 1); bwe2 = (chip == 2);
		@(negedge clk); bwe1 = 0; bwe2 = 0;
	endtask

	initial begin
		string dir, img;
		int    f, n, fd, fc, chip, phrase, att, bnk, count, ncase = 0;
		if (!$value$plusargs("DIR=%s", dir)) $fatal(1, "+DIR=<case directory> missing");
		if (!$value$plusargs("IMG=%s", img)) $fatal(1, "+IMG=<debug/<set>-image.sdram> missing");
		f = $fopen(img, "rb");
		if (f == 0) $fatal(1, "cannot open %s", img);
		n = $fread(u_chip.mem, f);
		$fclose(f);
		fc = $fopen({dir, "/cases.txt"}, "r");
		if (fc == 0) $fatal(1, "cannot open %s/cases.txt", dir);
		fd = $fopen({dir, "/rtl.txt"}, "w");

		repeat (20) @(posedge clk);
		reset = 0;
		repeat (2000) @(posedge clk);           // sdram.sv's power-up sequence

		while ($fscanf(fc, "%d %d %d %d %d\n", chip, phrase, att, bnk, count) == 5) begin
			set_bank(chip, 2'(bnk));
			write(chip, 8'h80 | 8'(phrase));
			$fwrite(fd, "case %0d %0d %0d %0d %0d\n", chip, phrase, att, bnk, count);
			fork
				write(chip, 8'h10 | 8'(att));    // voice 0 (bit 4), attenuation
				for (int i = 0; i < count; i++) begin
					if (chip == 1) @(posedge clk iff u_snd.u_oki1.cen_sr);
					else           @(posedge clk iff u_snd.u_oki2.cen_sr);
					$fwrite(fd, "%0d\n", chip == 1 ? u_snd.oki1_snd : u_snd.oki2_snd);
				end
			join
			write(chip, 8'h08);                  // stop voice 0
			repeat (40 * 54 * 165) @(posedge clk);   // ~40 samples of silence
			ncase++;
		end
		$fclose(fd);
		$fclose(fc);
		$display("%0d cases recorded to %s/rtl.txt", ncase, dir);
		$finish;
	end
endmodule
