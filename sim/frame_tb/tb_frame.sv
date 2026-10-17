`timescale 1ns/1ps
// Whole frames from captured MAME state, through dreamworld_top and the real SDRAM path.
//
// The set's ROM image is read into the chip model; a capture's sprite RAM, palette, VRAM and
// 0x804000 region are written through the core's CPU write ports (the maincpu output nets,
// forced while the 68020 is paused), so the palette mirror and both vregs copies and latches
// fill as they do when the game writes them. The raster then runs and two whole frames after
// the first vblank are recorded, blanking included, for scripts/frame_compare.py.
//
// RUN FROM THE REPOSITORY ROOT, after python sim/frame_tb/prep.py <capture>:
//     scripts/run_sim.sh frame_tb +CAP=debug/dreamwld-sw600 +IMG=debug/dreamwld-image.sdram
//         [+FRAMES=2] [+DIS=n] [+FLIP=1]   DIS: dbg_render_dis (bit 0 sprites, 1 layer 0, 2 layer 1);
//         FLIP: flip screen (compare with scripts/frame_compare.py --flip)
//         CPUTRAFFIC=n: a 68020-like program-ROM read on Port 2 every n clk (contention)
// Writes <CAP>/rtl_frames.hex: one line per pixel clock, {vblank, hblank} as one hex digit then
// rgb[14:0] as four, 444 x 263 a frame.
module tb_frame;
	localparam real HALF = 9.2593;      // 54 MHz
	logic clk = 0;
	always #(HALF) clk = ~clk;
	logic [2:0] ce_div = 0;
	logic       ce_pix;
	always_ff @(posedge clk) ce_div <= ce_div + 3'd1;
	assign ce_pix = (ce_div == 3'd0);   // DreamWorld.sv: clk_sys / 8

	logic reset = 1;
	logic [2:0] dis = 3'd0;
	logic       flip = 1'b0;
	logic [8:0]  hcnt, vcnt;
	logic        hblank, vblank, hsync, vsync;
	logic [14:0] rgb;

	wire  [15:0] SDRAM_DQ;
	logic [12:0] SDRAM_A;
	logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;
	logic [1:0]  SDRAM_BA;

	dreamworld_top dut (
		.hs_address(17'd0), .hs_data_in(8'd0), .hs_data_out(), .hs_read(1'b0), .hs_write(1'b0),
		.dbg_overlay(1'b0), .dbg_render_dis(dis), .pause(1'b1),
		.dbg_src(2'd0), .dbg_window(4'd0), .dbg_rearm(1'b0), .dbg_pixel(),
		.ldr_active(1'b0), .ldr_req(1'b0), .ldr_addr(25'd0), .ldr_data(16'd0), .ldr_we16(1'b0), .ldr_busy(),
		.clk(clk), .ce_pix(ce_pix), .reset(reset), .init(1'b0),
		.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),
		.ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(25'd0),
		.ioctl_dout(8'd0), .ioctl_wait(),
		.p1p2_in(32'hffffffff), .dsw_in(32'hffffffff), .flip(flip), .has_oki2(1'b1),
		.hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync), .rgb(rgb)
	);

	sdram_chip_model_wide chip (
		.clk(clk),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
	);

	// ---- the CPU write ports, driven from here while loading ----
	logic [15:0] st [0:5*4096-1];
	logic [12:0] ld_addr = 0;
	logic [15:0] ld_data = 0;
	logic        ld_spr = 0, ld_pal = 0, ld_v0 = 0, ld_v1 = 0, ld_vr = 0;

	task automatic load_state();
		force dut.u_core.spr_cpu_addr   = ld_addr[11:0];
		force dut.u_core.spr_cpu_wdata  = ld_data;
		force dut.u_core.spr_cpu_wel    = ld_spr;
		force dut.u_core.spr_cpu_weh    = ld_spr;
		force dut.u_core.pal_cpu_addr   = ld_addr[11:0];
		force dut.u_core.pal_cpu_wdata  = ld_data;
		force dut.u_core.pal_cpu_wel    = ld_pal;
		force dut.u_core.pal_cpu_weh    = ld_pal;
		force dut.u_core.vram0_cpu_addr = ld_addr[11:0];
		force dut.u_core.vram0_cpu_wdata = ld_data;
		force dut.u_core.vram0_cpu_wel  = ld_v0;
		force dut.u_core.vram0_cpu_weh  = ld_v0;
		force dut.u_core.vram1_cpu_addr = ld_addr[11:0];
		force dut.u_core.vram1_cpu_wdata = ld_data;
		force dut.u_core.vram1_cpu_wel  = ld_v1;
		force dut.u_core.vram1_cpu_weh  = ld_v1;
		force dut.u_core.vregs_cpu_addr = ld_addr;
		force dut.u_core.vregs_cpu_wdata = ld_data;
		force dut.u_core.vregs_cpu_wel  = ld_vr;
		force dut.u_core.vregs_cpu_weh  = ld_vr;
		for (int r = 0; r < 5; r++) begin
			for (int i = 0; i < 4096; i++) begin
				@(negedge clk);
				ld_addr = 13'(i);
				ld_data = st[r * 4096 + i];
				{ld_spr, ld_pal, ld_v0, ld_v1, ld_vr} = 5'b10000 >> r;
			end
		end
		@(negedge clk);
		{ld_spr, ld_pal, ld_v0, ld_v1, ld_vr} = 5'b00000;
		@(negedge clk);
		release dut.u_core.spr_cpu_addr;   release dut.u_core.spr_cpu_wdata;
		release dut.u_core.spr_cpu_wel;    release dut.u_core.spr_cpu_weh;
		release dut.u_core.pal_cpu_addr;   release dut.u_core.pal_cpu_wdata;
		release dut.u_core.pal_cpu_wel;    release dut.u_core.pal_cpu_weh;
		release dut.u_core.vram0_cpu_addr; release dut.u_core.vram0_cpu_wdata;
		release dut.u_core.vram0_cpu_wel;  release dut.u_core.vram0_cpu_weh;
		release dut.u_core.vram1_cpu_addr; release dut.u_core.vram1_cpu_wdata;
		release dut.u_core.vram1_cpu_wel;  release dut.u_core.vram1_cpu_weh;
		release dut.u_core.vregs_cpu_addr; release dut.u_core.vregs_cpu_wdata;
		release dut.u_core.vregs_cpu_wel;  release dut.u_core.vregs_cpu_weh;
	endtask

	// ---- Port 2 traffic standing in for the 68020 (+CPUTRAFFIC=n): a program-ROM read at a random
	// address every n clk through the core's own request port, each one a miss in the bridge's
	// granule cache, so the spritelut reads queue behind them as on the board ----
	int cpu_every = 0, cpu_cnt = 0;
	logic        cpu_req_f = 0;
	logic [19:0] cpu_addr_f = 0;
	always @(posedge clk) if (cpu_every > 0 && !reset) begin
		cpu_req_f <= 1'b0;
		if (cpu_cnt >= cpu_every - 1) begin
			cpu_cnt    <= 0;
			cpu_req_f  <= 1'b1;
			cpu_addr_f <= 20'($urandom);
		end else cpu_cnt <= cpu_cnt + 1;
	end

	// ---- recording ----
	int    fd, frames = 2, nrec = 0;
	logic  recording = 0;
	always @(posedge clk) if (recording && ce_pix) begin
		$fwrite(fd, "%1x%04x\n", {vblank, hblank}, {1'b0, rgb});
		nrec++;
	end

	initial begin
		string cap, img;
		int    f, n;
		if (!$value$plusargs("CAP=%s", cap)) $fatal(1, "+CAP=<capture dir> missing");
		if (!$value$plusargs("IMG=%s", img)) $fatal(1, "+IMG=<debug/<set>-image.sdram> missing");
		void'($value$plusargs("FRAMES=%d", frames));
		void'($value$plusargs("DIS=%d", dis));
		void'($value$plusargs("FLIP=%d", flip));
		void'($value$plusargs("CPUTRAFFIC=%d", cpu_every));
		if (cpu_every > 0) begin
			force dut.u_core.cpu_rom_req  = cpu_req_f;
			force dut.u_core.cpu_rom_addr = cpu_addr_f;
		end
		$readmemh({cap, "/cpu_state.hex"}, st);
		f = $fopen(img, "rb");
		if (f == 0) $fatal(1, "cannot open %s", img);
		n = $fread(chip.mem, f);
		$fclose(f);
		$display("image: %0d bytes into the chip model", n);

		repeat (20) @(posedge clk);
		reset = 0;
		repeat (20) @(posedge clk);
		load_state();
		$display("%t: state loaded (vcnt %0d)", $time, vcnt);

		@(posedge vblank);
		@(negedge vblank);
		// the frame starts at the first pixel clock of line 0
		wait (vcnt == 0 && hcnt == 0 && ce_pix);
		fd = $fopen({cap, "/rtl_frames.hex"}, "w");
		recording = 1;
		repeat (frames * 444 * 263) @(posedge clk iff ce_pix);
		recording = 0;
		$fclose(fd);
		$display("%t: %0d pixel clocks recorded to %s/rtl_frames.hex", $time, nrec, cap);
		$display("sprite lines cut short %0d, worst sprite render %0d clk (of %0d frames run)",
		         dut.u_core.sp_ovr_cnt, dut.u_core.sp_render_max, dut.u_core.ovr_frames);
		$finish;
	end
endmodule
