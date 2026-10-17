`timescale 1ns/1ps
// A set's boot on maincpu + semicom_mcu, against MAME. The program ROM and the MCU ROM are the
// set's .mra image (sim/boot_tb/gen_fixture.py); RAM regions are block-RAM models; inputs idle;
// DSW at the .mra default; OKIs idle (0xF0); vblank from a 444 x 263 raster at 6.75 MHz.
//
// Writes, for scripts/compare_boot_trace.py, every bus access the 68020 completes, in MAME's
// "seq rw addr mask data" form (32-bit-aligned address, byte-lane mask, data in its lanes) to
// debug/<set>-boot/<set>_rtl.trace, up to +MAXACC accesses. Checks, from MAME's trace
// (docs/boot_trace_mame.txt): every byte the 68020 reads at 0xC00030 against the MCU ROM from
// 0x3C, and that the vblank interrupt is taken and runs the handler copied to 0xFFD000.
//
// RUN FROM THE REPOSITORY ROOT, after python sim/boot_tb/gen_fixture.py:
//     scripts/run_sim.sh boot_tb [+MS=n] [+MAXACC=n] [+SET=dreamwld] [+DSW=hhhh]
module tb_boot;
	localparam real HALF = 9.2593;          // 54 MHz clk_sys
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic reset = 1;

	// ---- raster: 444 x 263 at 6.75 MHz = 3552 clk a line; vblank lines 224-262 ----
	int unsigned hc = 0, vc = 0;
	logic vblank = 0;
	always_ff @(posedge clk) begin
		if (hc == 3551) begin
			hc <= 0;
			vc <= (vc == 262) ? 0 : vc + 1;
		end else hc <= hc + 1;
		vblank <= (vc >= 224);
	end

	// ---- program ROM: req/valid, 12-cycle latency (the SDRAM's uncontended read) ----
	logic [15:0] prg [0:1048575];
	initial $readmemh("sim/boot_tb/maincpu.hex", prg);
	logic         rom_req, rom_valid;
	logic [19:0] rom_addr, rom_addr_l;
	logic [15:0] rom_data;
	int           rom_cnt = -1;
	always_ff @(posedge clk) begin
		rom_valid <= 1'b0;
		if (rom_req) begin rom_cnt <= 12; rom_addr_l <= rom_addr; end
		else if (rom_cnt > 0) rom_cnt <= rom_cnt - 1;
		else if (rom_cnt == 0) begin rom_valid <= 1'b1; rom_data <= prg[rom_addr_l]; rom_cnt <= -1; end
	end

	// ---- block-RAM regions: one cycle of read latency, byte lanes ----
	logic [11:0] spriteram_addr, palette_addr, vram0_addr, vram1_addr;
	logic [12:0] vregs_addr;
	logic [15:0] workram_addr;
	logic        spriteram_wel, spriteram_weh, palette_wel, palette_weh, vram0_wel, vram0_weh;
	logic        vram1_wel, vram1_weh, vregs_wel, vregs_weh, workram_wel, workram_weh;
	logic [15:0] spriteram_wdata, palette_wdata, vram0_wdata, vram1_wdata, vregs_wdata, workram_wdata;
	logic [15:0] spriteram_rdata, palette_rdata, vram0_rdata, vram1_rdata, vregs_rdata, workram_rdata;
	logic [15:0] spriteram [0:4095], palette [0:4095], vram0 [0:4095], vram1 [0:4095];
	logic [15:0] vregs [0:8191], workram [0:65535];
	always @(posedge clk) begin
		spriteram_rdata <= spriteram[spriteram_addr];
		if (spriteram_wel) spriteram[spriteram_addr][7:0]  <= spriteram_wdata[7:0];
		if (spriteram_weh) spriteram[spriteram_addr][15:8] <= spriteram_wdata[15:8];
		palette_rdata <= palette[palette_addr];
		if (palette_wel) palette[palette_addr][7:0]  <= palette_wdata[7:0];
		if (palette_weh) palette[palette_addr][15:8] <= palette_wdata[15:8];
		vram0_rdata <= vram0[vram0_addr];
		if (vram0_wel) vram0[vram0_addr][7:0]  <= vram0_wdata[7:0];
		if (vram0_weh) vram0[vram0_addr][15:8] <= vram0_wdata[15:8];
		vram1_rdata <= vram1[vram1_addr];
		if (vram1_wel) vram1[vram1_addr][7:0]  <= vram1_wdata[7:0];
		if (vram1_weh) vram1[vram1_addr][15:8] <= vram1_wdata[15:8];
		vregs_rdata <= vregs[vregs_addr];
		if (vregs_wel) vregs[vregs_addr][7:0]  <= vregs_wdata[7:0];
		if (vregs_weh) vregs[vregs_addr][15:8] <= vregs_wdata[15:8];
		workram_rdata <= workram[workram_addr];
		if (workram_wel) workram[workram_addr][7:0]  <= workram_wdata[7:0];
		if (workram_weh) workram[workram_addr][15:8] <= workram_wdata[15:8];
	end

	// ---- I/O ----
	logic [15:0] dsw16 = 16'hffff;
	wire  [31:0] p1p2_in = 32'hffffffff;
	wire  [31:0] dsw_in  = {dsw16, dsw16};
	logic        oki1_wr, oki2_wr, oki1_bank_we, oki2_bank_we, prot_wr, prot_rd;
	logic [7:0]  oki_wdata, prot_latch;
	logic [1:0]  oki_bank;

	maincpu dut (
		.clk(clk), .reset(reset),
		.rom_req(rom_req), .rom_addr(rom_addr), .rom_valid(rom_valid), .rom_data(rom_data),
		.spriteram_addr(spriteram_addr), .spriteram_wel(spriteram_wel), .spriteram_weh(spriteram_weh),
		.spriteram_wdata(spriteram_wdata), .spriteram_rdata(spriteram_rdata),
		.palette_addr(palette_addr), .palette_wel(palette_wel), .palette_weh(palette_weh),
		.palette_wdata(palette_wdata), .palette_rdata(palette_rdata),
		.vram0_addr(vram0_addr), .vram0_wel(vram0_wel), .vram0_weh(vram0_weh),
		.vram0_wdata(vram0_wdata), .vram0_rdata(vram0_rdata),
		.vram1_addr(vram1_addr), .vram1_wel(vram1_wel), .vram1_weh(vram1_weh),
		.vram1_wdata(vram1_wdata), .vram1_rdata(vram1_rdata),
		.vregs_addr(vregs_addr), .vregs_wel(vregs_wel), .vregs_weh(vregs_weh),
		.vregs_wdata(vregs_wdata), .vregs_rdata(vregs_rdata),
		.workram_addr(workram_addr), .workram_wel(workram_wel), .workram_weh(workram_weh),
		.workram_wdata(workram_wdata), .workram_rdata(workram_rdata),
		.p1p2_in(p1p2_in), .dsw_in(dsw_in), .pause(1'b0),
		.has_oki2(1'b1),
		.oki1_wr(oki1_wr), .oki2_wr(oki2_wr), .oki_wdata(oki_wdata),
		.oki1_dout(8'hf0), .oki2_dout(8'hf0),
		.oki1_bank_we(oki1_bank_we), .oki2_bank_we(oki2_bank_we), .oki_bank(oki_bank),
		.prot_wr(prot_wr), .prot_rd(prot_rd), .prot_latch(prot_latch),
		.spr_hold(1'b0), .vblank(vblank)
	);

	logic        mcu_we = 0;
	logic [11:0] mcu_waddr = 0;
	logic [15:0] mcu_wdata = 0;
	semicom_mcu u_mcu (
		.clk(clk), .reset(reset),
		.rom_we(mcu_we), .rom_waddr(mcu_waddr), .rom_wdata(mcu_wdata), .rom_wbe(2'b11),
		.prot_wr(prot_wr), .prot_rd(prot_rd), .latch(prot_latch)
	);

	// ---- trace: one line per access the CPU consumes ----
	string set = "dreamwld";
	int    fd, nacc = 0, maxacc = 3000000;
	wire   consume = dut.cpu_clkena && (dut.busstate != 2'b01);
	always @(posedge clk) if (!reset && consume && nacc < maxacc) begin
		logic [31:0] mask, data;
		logic [15:0] w;
		logic        wr;
		wr   = (dut.busstate == 2'b11);
		w    = wr ? dut.cpu_dout : dut.acc_data;
		mask = {16'h0000, (dut.nUDS ? 8'h00 : 8'hff), (dut.nLDS ? 8'h00 : 8'hff)};
		if (wr == 0 && dut.nUDS && dut.nLDS) mask[15:0] = 16'hffff;   // a fetch drives no strobes
		data = {16'h0000, w};
		if (!dut.a32[1]) begin mask = mask << 16; data = data << 16; end
		nacc++;
		$fwrite(fd, "%0d\t%s\t%06X\t%08X\t%08X\n", nacc, wr ? "w" : "r", {dut.a32[23:2], 2'b00}, mask, data & mask);
	end

	// ---- protection stream and the interrupt ----
	logic [7:0] stream [0:1736];
	initial $readmemh("sim/boot_tb/stream.hex", stream);
	int nprot = 0, prot_bad = 0, iacks = 0, handler = 0;
	logic [7:0] got;
	always @(posedge clk) if (!reset) begin
		if (dut.prot_wr && nprot == 0) $display("%t: first write to 0xC00020 (MAME: frame 55, 0.95 s)", $time);
		if (consume && dut.fc == 3'b111 && iacks == 0) $display("%t: first interrupt acknowledge", $time);
		if (dut.prot_rd) begin
			// the latch the access returns is captured on this clk (read_mux, acc_ph 2)
			got = prot_latch;
			if (nprot < 1737 && got !== stream[nprot]) begin
				prot_bad++;
				if (prot_bad <= 5) $display("FAIL C00030 byte %0d: %02x, MCU ROM 0x%03x is %02x", nprot, got, 16'h3c + nprot, stream[nprot]);
			end
			nprot++;
			if (nprot == 1737) $display("%t: protection stream complete, %0d bytes, %0d wrong", $time, nprot, prot_bad);
		end
		if (consume && dut.fc == 3'b111) iacks++;
		if (consume && dut.busstate == 2'b00 && dut.a32[23:0] == 24'hffd000) begin
			handler++;
			if (handler == 1) $display("%t: first fetch at 0xFFD000 (vblank handler), %0d interrupt acknowledges so far", $time, iacks);
		end
	end

	int ms = 1900;
	initial begin
		string dsw_s;
		void'($value$plusargs("MS=%d", ms));
		void'($value$plusargs("MAXACC=%d", maxacc));
		void'($value$plusargs("SET=%s", set));
		if ($value$plusargs("DSW=%h", dsw16)) ;
		fd = $fopen($sformatf("debug/%s-boot/%s_rtl.trace", set, set), "w");
		if (fd == 0) $fatal(1, "cannot open debug/%s-boot/%s_rtl.trace (run mame_boot_trace.py first)", set, set);
		$fwrite(fd, "# RTL bus accesses from reset (sim/boot_tb), seq rw addr mask data\n");
		// the MCU ROM, through its write port, as the download delivers it
		begin
			logic [15:0] mcu [0:4095];
			$readmemh("sim/boot_tb/mcu.hex", mcu);
			for (int i = 0; i < 4096; i++) begin
				@(posedge clk) begin mcu_we <= 1; mcu_waddr <= 12'(i); mcu_wdata <= mcu[i]; end
			end
			@(posedge clk) mcu_we <= 0;
		end
		repeat (20) @(posedge clk);
		reset = 0;
		fork
			begin wait (handler >= 3); repeat (1000) @(posedge clk); end
			begin #(longint'(ms) * 1ms); end
		join_any
		disable fork;
		$fclose(fd);
		$display("%0d accesses traced; C00030 reads %0d (%0d wrong); interrupt acknowledges %0d; handler entries %0d",
		         nacc, nprot, prot_bad, iacks, handler);
		if (nprot >= 1737 && prot_bad == 0 && handler > 0)
			$display("PASS: protection stream received intact and the vblank handler at 0xFFD000 runs");
		else
			$display("FAIL: stream %0d/1737 (%0d wrong), handler entries %0d", nprot, prot_bad, handler);
		$finish;
	end
endmodule
