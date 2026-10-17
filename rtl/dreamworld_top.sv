// rtl/dreamworld_core.sv (CPU + video) wired to rtl/memory/dreamworld_sdram_top.sv
// (the ROM store). The ROM port shapes of the two modules match, so this is
// a port-to-port connection plus the two reset domains below.
//
// Two reset domains, because MiSTer holds the core's RESET for the whole ROM
// download (measured on hardware in the Psikyo core this was taken from):
//   * core_reset holds the CPU and video logic during the download and the
//     DDR3 -> SDRAM copy, when there is no complete ROM to run.
//   * sdram_reset must be LOW during the download, or sdram_download's FSM
//     never leaves idle and every downloaded byte is dropped without error.
//     Upstream Sorgelig sdram.v has no reset port for this reason; this
//     project's wrappers added one, so it is held off here.
module dreamworld_top #(
	parameter bit DEBUG_TRACER = 1'b1
) (
	input  logic clk,
	input  logic ce_pix,
	input  logic reset,
	input  logic init,

	output logic [12:0] SDRAM_A,
	output logic         SDRAM_DQML,
	output logic         SDRAM_DQMH,
	output logic [1:0]  SDRAM_BA,
	output logic         SDRAM_nCS,
	output logic         SDRAM_nWE,
	output logic         SDRAM_nRAS,
	output logic         SDRAM_nCAS,
	output logic         SDRAM_CLK,
	output logic         SDRAM_CKE,
	inout  wire [15:0]  SDRAM_DQ,

	// HPS ROM download.
	input  logic         ioctl_download,
	input  logic [15:0] ioctl_index,
	input  logic         ioctl_wr,
	input  logic [24:0] ioctl_addr,
	input  logic [7:0]  ioctl_dout,
	output logic         ioctl_wait,

	// Inputs (raw values -- caller owns debouncing/mapping).
	input  logic [31:0] p1p2_in,
	input  logic [31:0] dsw_in,
	input  logic         flip,
	input  logic         has_oki2,

	// Fast ROM load write port (rtl/memory/rom_loader.sv, driven at the top)
	input  logic         ldr_active,
	input  logic         ldr_req,
	input  logic [24:0] ldr_addr,
	input  logic [15:0] ldr_data,
	input  logic         ldr_we16,
	output logic         ldr_busy,   // see dreamworld_sdram_top.sv's port comment

	// Video output.
	output logic [8:0]  hcnt,
	output logic [8:0]  vcnt,
	output logic         hblank,
	output logic         vblank,
	output logic         hsync,
	output logic         vsync,
	output logic [14:0] rgb,

	// Sound: both OKIs mixed to mono, signed 16-bit
	output logic [15:0] audio,

	// ---- debug tracer, live-controlled from the OSD ----
	input  logic         dbg_overlay,
	input  logic [2:0]  dbg_render_dis,
	input  logic         pause,

	// hiscore work-RAM access (rtl/hiscore.v) -- see dreamworld_core's ports
	input  logic [16:0] hs_address,
	input  logic [7:0]  hs_data_in,
	output logic [7:0]  hs_data_out,
	input  logic         hs_read,
	input  logic         hs_write,
`ifdef DEBUG_ISSP
	input  logic         dbg_autopause_frame_en,
`endif
	input  logic [1:0]  dbg_src,
	input  logic [3:0]  dbg_window,
	input  logic         dbg_rearm,
	output logic [23:0] dbg_pixel
);

	logic         cpu_rom_req;
	logic [19:0] cpu_rom_addr;
	logic         cpu_rom_valid;
	logic [15:0] cpu_rom_data;

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

	logic         oki1_rom_req, oki2_rom_req, oki1_rom_valid, oki2_rom_valid;
	logic [19:0] oki1_rom_addr, oki2_rom_addr;
	logic [7:0]  oki1_rom_data, oki2_rom_data;

	logic         mcu_rom_we;
	logic [11:0] mcu_rom_waddr;
	logic [15:0] mcu_rom_wdata;
	logic [1:0]  mcu_rom_wbe;

	// ldr_active holds the core off while the bulk DDR3 -> SDRAM copy runs,
	// exactly as ioctl_download does for the byte-streaming path.
	logic core_reset, sdram_reset;
	assign core_reset  = reset | ioctl_download | ldr_active;
	assign sdram_reset = reset & ~ioctl_download;

	dreamworld_core #(.DEBUG_TRACER(DEBUG_TRACER)) u_core (
		.clk(clk), .ce_pix(ce_pix), .reset(core_reset), .video_reset(reset),
		.cpu_rom_req(cpu_rom_req), .cpu_rom_addr(cpu_rom_addr),
		.cpu_rom_valid(cpu_rom_valid), .cpu_rom_data(cpu_rom_data),
		.l0_gfxrom_req(l0_gfxrom_req), .l0_gfxrom_addr(l0_gfxrom_addr),
		.l0_gfxrom_valid(l0_gfxrom_valid), .l0_gfxrom_data(l0_gfxrom_data),
		.l1_gfxrom_req(l1_gfxrom_req), .l1_gfxrom_addr(l1_gfxrom_addr),
		.l1_gfxrom_valid(l1_gfxrom_valid), .l1_gfxrom_data(l1_gfxrom_data),
		.sp_gfxrom_req(sp_gfxrom_req), .sp_gfxrom_addr(sp_gfxrom_addr),
		.sp_gfxrom_valid(sp_gfxrom_valid), .sp_gfxrom_data(sp_gfxrom_data),
		.sp_lut_req(sp_lut_req), .sp_lut_addr(sp_lut_addr),
		.sp_lut_valid(sp_lut_valid), .sp_lut_data(sp_lut_data),
		.oki1_rom_req(oki1_rom_req), .oki1_rom_addr(oki1_rom_addr),
		.oki1_rom_valid(oki1_rom_valid), .oki1_rom_data(oki1_rom_data),
		.oki2_rom_req(oki2_rom_req), .oki2_rom_addr(oki2_rom_addr),
		.oki2_rom_valid(oki2_rom_valid), .oki2_rom_data(oki2_rom_data),
		.audio(audio),
		.p1p2_in(p1p2_in), .dsw_in(dsw_in), .flip(flip), .has_oki2(has_oki2),
		.mcu_rom_we(mcu_rom_we), .mcu_rom_waddr(mcu_rom_waddr),
		.mcu_rom_wdata(mcu_rom_wdata), .mcu_rom_wbe(mcu_rom_wbe),
		.hcnt(hcnt), .vcnt(vcnt), .hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync), .rgb(rgb),
		.dbg_overlay(dbg_overlay), .dbg_render_dis(dbg_render_dis), .pause(pause),
		.hs_address(hs_address), .hs_data_in(hs_data_in),
		.hs_data_out(hs_data_out), .hs_read(hs_read), .hs_write(hs_write),
`ifdef DEBUG_ISSP
		.dbg_autopause_frame_en(dbg_autopause_frame_en),
`endif
		.dbg_src(dbg_src), .dbg_window(dbg_window), .dbg_rearm(dbg_rearm),
		.dbg_pixel(dbg_pixel)
	);

	dreamworld_sdram_top u_sdram (
		.clk(clk), .reset(sdram_reset), .init(init),
		.SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_DQ(SDRAM_DQ),
		.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
		.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
		.ioctl_wait(ioctl_wait),
		.ldr_active(ldr_active), .ldr_req(ldr_req), .ldr_addr(ldr_addr),
		.ldr_data(ldr_data), .ldr_we16(ldr_we16), .ldr_busy(ldr_busy),
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
		.oki1_rom_req(oki1_rom_req), .oki1_rom_addr(oki1_rom_addr),
		.oki1_rom_valid(oki1_rom_valid), .oki1_rom_data(oki1_rom_data),
		.oki2_rom_req(oki2_rom_req), .oki2_rom_addr(oki2_rom_addr),
		.oki2_rom_valid(oki2_rom_valid), .oki2_rom_data(oki2_rom_data),
		.mcu_rom_we(mcu_rom_we), .mcu_rom_waddr(mcu_rom_waddr),
		.mcu_rom_wdata(mcu_rom_wdata), .mcu_rom_wbe(mcu_rom_wbe)
	);

endmodule
