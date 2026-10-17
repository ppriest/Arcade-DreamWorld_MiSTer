// CPU + video core: wires rtl/cpu/maincpu.sv (the 68EC020 bus) into the
// memory glue (rtl/memory/dpram.sv, rtl/video/vreg_decode.sv,
// rtl/video/spriteram_dbuf.sv) and the video pipeline
// (rtl/video/video_timing.sv, tilemap_line_engine.sv x2, the per-scanline
// sprite path, compositor.sv). ROM contents are external, behind the
// req/valid ports (rtl/memory/dreamworld_sdram_top.sv); HPS/DIP/CRT glue is
// one level up in DreamWorld.sv.
//
// The video pipeline is still the Psikyo core's (psikyo_v.cpp) apart from
// vreg_decode's control word; dreamwld.cpp's sprite format, sprite LUT
// redirect, layer offsets and 308-pixel screen are not implemented yet.
//
// ---- Sprite pipeline per-frame sequencing ----
// Per-scanline sprites, sequenced to psikyo_v.cpp's screen_vblank(): at
// frame_start, sprite_line_list rebuilds its compact table FROM the
// spriteram snapshot (get_sprites), then spriteram_dbuf.copy_start
// refreshes that snapshot from the live RAM (m_spriteram->copy) -- the
// capture is at the frame boundary and the table a frame renders from is
// one buffer-generation old, both exactly the reference. Each visible
// line is then rendered one line ahead of scanout into a double 320-pixel
// line buffer; line_start hard-resyncs an overrunning render (clipping at
// worst that one line's tail sprites, counted on the debug overlay). The
// whole-frame renderer + 1.7 Mbit frame buffer this replaced, and its
// history, are recorded in docs/sprite_buffering.md.
module dreamworld_core #(
	parameter bit DEBUG_TRACER  = 1'b1
) (
	input  logic clk,
	input  logic ce_pix,
	input  logic reset,
	// Video timing runs from its OWN reset, which does NOT include the ROM
	// download. Holding the timing generator in reset for the whole load stops
	// HSync/VSync entirely: an HDMI scaler rides that out, but a CRT drops sync
	// and shows nothing while the game loads. Only the game logic is reset by
	// `reset`; the raster keeps running so the display stays locked.
	input  logic video_reset,

	// CPU program ROM -- external (SDRAM stack).
	output logic         cpu_rom_req,
	output logic [19:0] cpu_rom_addr,     // word address, 2 MB
	input  logic         cpu_rom_valid,
	input  logic [15:0] cpu_rom_data,

	// Tilemap layer 0/1 gfx ROM -- external.
	output logic         l0_gfxrom_req,
	output logic [21:0] l0_gfxrom_addr,
	input  logic         l0_gfxrom_valid,
	input  logic [63:0] l0_gfxrom_data,
	output logic         l1_gfxrom_req,
	output logic [21:0] l1_gfxrom_addr,
	input  logic         l1_gfxrom_valid,
	input  logic [63:0] l1_gfxrom_data,

	// Sprite gfx ROM + spritelut -- external.
	output logic         sp_gfxrom_req,
	output logic [22:0] sp_gfxrom_addr,
	input  logic         sp_gfxrom_valid,
	input  logic [63:0] sp_gfxrom_data,
	output logic         sp_lut_req,
	output logic [16:0] sp_lut_addr,
	input  logic         sp_lut_valid,
	input  logic [15:0] sp_lut_data,

	// OKI sample ROMs -- external. The address is {bank, the chip's 18-bit address}; the
	// SDRAM side maps it (oki1_map: the bank moves 0x30000-0x3FFFF only). Byte reads, held req.
	output logic         oki1_rom_req,
	output logic [19:0] oki1_rom_addr,
	input  logic         oki1_rom_valid,
	input  logic [7:0]  oki1_rom_data,
	output logic         oki2_rom_req,
	output logic [19:0] oki2_rom_addr,
	input  logic         oki2_rom_valid,
	input  logic [7:0]  oki2_rom_data,

	// Both OKIs mixed to mono, signed 16-bit
	output logic [15:0] audio,

	// Inputs (raw values -- caller owns debouncing/mapping).
	input  logic [31:0] p1p2_in,
	input  logic [31:0] dsw_in,
	// Flip screen, latched at frame start: every layer renders the unflipped
	// frame rotated 180 degrees.
	input  logic         flip,
	input  logic         has_oki2,      // .mra mod byte: dreamwld_map sets

	// MCU program ROM writes, from the download (dreamworld_sdram_top's tap).
	input  logic         mcu_rom_we,
	input  logic [11:0] mcu_rom_waddr,
	input  logic [15:0] mcu_rom_wdata,
	input  logic [1:0]  mcu_rom_wbe,

	// ---- hiscore access to work RAM (rtl/hiscore.v) ----
	// Byte address within the 128KB work RAM (0xFE0000-0xFFFFFF); the
	// module's configured 24-bit addresses are 0xFExxxx, whose low 17 bits
	// ARE the offset, so no subtraction is needed. Reads use the work RAM's
	// otherwise-unused second port; writes borrow the CPU port, which is
	// safe because hiscore only writes while it has the CPU paused.
	input  logic [16:0] hs_address,
	input  logic [7:0]  hs_data_in,     // byte to write into work RAM
	output logic [7:0]  hs_data_out,    // byte read from work RAM
	input  logic         hs_read,        // hiscore wants to read (ram_intent_read)
	input  logic         hs_write,

	// Video output.
	output logic [8:0]  hcnt,
	output logic [8:0]  vcnt,
	output logic         hblank,
	output logic         vblank,
	output logic         hsync,
	output logic         vsync,
	output logic [14:0] rgb,

	// ---- debug tracer (rtl/debug/debug_tracer.sv) ----
	// Live-controlled from the OSD; see that module's header. Compiled out
	// entirely when DEBUG_TRACER = 0.
	input  logic         dbg_overlay,  // overlay is being displayed (frees VRAM read ports)
	// Force-disable rendering per layer, from the OSD. Purely a debugging aid:
	// it isolates which pipeline actually drew a given thing on screen, which
	// is otherwise guesswork once sprites and tilemaps overlap.
	//   [0] sprites  [1] tilemap layer 0  [2] tilemap layer 1
	input  logic [2:0]  dbg_render_dis,
	// Freeze the main CPU, so a frame can be captured and compared against a
	// MAME dump of the same moment without the game advancing underneath it.
	input  logic         pause,
`ifdef DEBUG_ISSP
	// Pause N frames after an arm over JTAG, OSD-gated -- see the auto-pause
	// block below.
	input  logic         dbg_autopause_frame_en,
`endif
	input  logic [1:0]  dbg_src,      // which signal group to record
	input  logic [3:0]  dbg_window,   // skip dbg_window*256 events first
	input  logic         dbg_rearm,    // any change restarts capture
	output logic [23:0] dbg_pixel     // one captured entry per scanline
);

	// ---- video timing ----
	logic [7:0] vcnt_active;
	logic [7:0] vcnt_next_active;
	logic [7:0] vcnt_next2_active;
	logic         h_active, v_active;
	logic         line_start, frame_start;

	video_timing u_timing (
		.clk(clk), .ce_pix(ce_pix), .reset(video_reset),
		.hcnt(hcnt), .vcnt(vcnt), .vcnt_active(vcnt_active), .vcnt_next_active(vcnt_next_active),
		.vcnt_next2_active(vcnt_next2_active),
		.h_active(h_active), .v_active(v_active),
		.hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync),
		.line_start(line_start), .frame_start(frame_start)
	);

	// ---- Flip screen ----
	// Every layer renders screen line y from source line 223-y and reads it
	// right to left. Latched at frame start so a change never tears a frame.
	logic flip_screen;
	always_ff @(posedge clk or posedge video_reset) begin
		if (video_reset)      flip_screen <= 1'b0;
		else if (frame_start) flip_screen <= flip;
	end

`ifdef DEBUG_ISSP
	// Frame-count auto-pause: pause N frames after the last (re)arm, for when
	// the target screen is known but no address/value to trigger on is. The
	// OSD enable keeps it from firing unless asked for. Source layout: bit 16
	// = rearm pulse (rising edge starts a fresh count), bits 15:0 = target
	// frame count.
	wire [16:0] frame_pause_src;
	logic         frame_pause_rearm_d, frame_pause_armed, frame_pause_fired;
	logic [15:0] frame_pause_target, frame_pause_count;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			frame_pause_rearm_d <= 1'b0;
			frame_pause_armed    <= 1'b0;
			frame_pause_fired    <= 1'b0;
			frame_pause_count    <= 16'd0;
		end else begin
			frame_pause_rearm_d <= frame_pause_src[16];
			if (frame_pause_src[16] & ~frame_pause_rearm_d) begin
				frame_pause_target <= frame_pause_src[15:0];
				frame_pause_count  <= 16'd0;
				frame_pause_armed  <= 1'b1;
				frame_pause_fired  <= 1'b0;
			end else if (!dbg_autopause_frame_en) begin
				frame_pause_armed <= 1'b0;
				frame_pause_fired <= 1'b0;   // OSD-disabling also clears it
			end else if (frame_pause_armed && frame_start) begin
				if (frame_pause_count == frame_pause_target) begin
					frame_pause_fired <= 1'b1;
					frame_pause_armed <= 1'b0;
				end else begin
					frame_pause_count <= frame_pause_count + 1'b1;
				end
			end
		end
	end

	altsource_probe #(
		.sld_auto_instance_index("YES"),
		.instance_id("F"),
		.probe_width(16),
		.source_width(17),
		.source_initial_value("0"),
		.enable_metastability("NO"),
		.lpm_type("altsource_probe")
	) u_issp_framepause (
		.probe(frame_pause_count),
		.source(frame_pause_src),
		.source_clk(clk),
		.source_ena(1'b1)
	);

	wire auto_pause_frame = dbg_autopause_frame_en && frame_pause_fired;
`endif

	// Declared before maincpu uses it: a port bound to a not-yet-declared
	// name gets an implicit 1-bit net, and ModelSim rejects the later
	// declaration (vlog-2388).
	// Combined pause: the manual button plus the frame-count trigger when
	// enabled. In a non-DEBUG_ISSP build this reduces to exactly `pause`.
	logic spr_copy_busy;   // sprite RAM copy running (spriteram_dbuf), declared here for maincpu

	wire effective_pause = pause
`ifdef DEBUG_ISSP
		| auto_pause_frame
`endif
		;

	// ---- CPU-facing BRAM region ports (maincpu.sv's own port shapes) ----
	logic [11:0] spr_cpu_addr;
	logic         spr_cpu_wel, spr_cpu_weh;
	logic [15:0] spr_cpu_wdata, spr_cpu_rdata;

	logic [11:0] pal_cpu_addr;
	logic         pal_cpu_wel, pal_cpu_weh;
	logic [15:0] pal_cpu_wdata, pal_cpu_rdata;

	logic [11:0] vram0_cpu_addr;
	logic         vram0_cpu_wel, vram0_cpu_weh;
	logic [15:0] vram0_cpu_wdata, vram0_cpu_rdata;

	logic [11:0] vram1_cpu_addr;
	logic         vram1_cpu_wel, vram1_cpu_weh;
	logic [15:0] vram1_cpu_wdata, vram1_cpu_rdata;

	logic [12:0] vregs_cpu_addr;
	logic         vregs_cpu_wel, vregs_cpu_weh;
	logic [15:0] vregs_cpu_wdata, vregs_cpu_rdata;

	logic [15:0] workram_cpu_addr;
	logic         workram_cpu_wel, workram_cpu_weh;
	logic [15:0] workram_cpu_wdata, workram_cpu_rdata;

	logic        oki1_wr, oki2_wr, oki1_bank_we, oki2_bank_we;
	logic [7:0]  oki_wdata, oki1_dout, oki2_dout;
	logic [1:0]  oki_bank;
	logic        prot_wr, prot_rd;
	logic [7:0]  prot_latch;

	maincpu u_cpu (
		.clk(clk), .reset(reset),
		.rom_req(cpu_rom_req), .rom_addr(cpu_rom_addr), .rom_valid(cpu_rom_valid), .rom_data(cpu_rom_data),
		.spriteram_addr(spr_cpu_addr), .spriteram_wel(spr_cpu_wel), .spriteram_weh(spr_cpu_weh),
		.spriteram_wdata(spr_cpu_wdata), .spriteram_rdata(spr_cpu_rdata),
		.palette_addr(pal_cpu_addr), .palette_wel(pal_cpu_wel), .palette_weh(pal_cpu_weh),
		.palette_wdata(pal_cpu_wdata), .palette_rdata(pal_cpu_rdata),
		.vram0_addr(vram0_cpu_addr), .vram0_wel(vram0_cpu_wel), .vram0_weh(vram0_cpu_weh),
		.vram0_wdata(vram0_cpu_wdata), .vram0_rdata(vram0_cpu_rdata),
		.vram1_addr(vram1_cpu_addr), .vram1_wel(vram1_cpu_wel), .vram1_weh(vram1_cpu_weh),
		.vram1_wdata(vram1_cpu_wdata), .vram1_rdata(vram1_cpu_rdata),
		.vregs_addr(vregs_cpu_addr), .vregs_wel(vregs_cpu_wel), .vregs_weh(vregs_cpu_weh),
		.vregs_wdata(vregs_cpu_wdata), .vregs_rdata(vregs_cpu_rdata),
		.workram_addr(workram_cpu_addr), .workram_wel(workram_cpu_wel), .workram_weh(workram_cpu_weh),
		.workram_wdata(workram_cpu_wdata), .workram_rdata(workram_cpu_rdata),
		.p1p2_in(p1p2_in), .dsw_in(dsw_in), .pause(effective_pause), .spr_hold(spr_copy_busy),
		.has_oki2(has_oki2),
		.oki1_wr(oki1_wr), .oki2_wr(oki2_wr), .oki_wdata(oki_wdata),
		.oki1_dout(oki1_dout), .oki2_dout(oki2_dout),
		.oki1_bank_we(oki1_bank_we), .oki2_bank_we(oki2_bank_we), .oki_bank(oki_bank),
		.prot_wr(prot_wr), .prot_rd(prot_rd), .prot_latch(prot_latch),
		.vblank(vblank)
	);

	// ---- protection MCU ----
	semicom_mcu u_mcu (
		.clk(clk), .reset(reset),
		.rom_we(mcu_rom_we), .rom_waddr(mcu_rom_waddr), .rom_wdata(mcu_rom_wdata), .rom_wbe(mcu_rom_wbe),
		.prot_wr(prot_wr), .prot_rd(prot_rd), .latch(prot_latch)
	);

	// ---- OKI M6295 x2 (rtl/sound/dreamworld_sound.sv) ----
	dreamworld_sound u_sound (
		.clk(clk), .reset(reset), .has_oki2(has_oki2),
		.oki1_wr(oki1_wr), .oki2_wr(oki2_wr), .wdata(oki_wdata),
		.oki1_dout(oki1_dout), .oki2_dout(oki2_dout),
		.oki1_bank_we(oki1_bank_we), .oki2_bank_we(oki2_bank_we), .bank(oki_bank),
		.oki1_rom_req(oki1_rom_req), .oki1_rom_addr(oki1_rom_addr),
		.oki1_rom_valid(oki1_rom_valid), .oki1_rom_data(oki1_rom_data),
		.oki2_rom_req(oki2_rom_req), .oki2_rom_addr(oki2_rom_addr),
		.oki2_rom_valid(oki2_rom_valid), .oki2_rom_data(oki2_rom_data),
		.audio(audio)
	);

	// ---- work RAM: CPU-only, port B unused ----
	// Work RAM is 16-bit words; hiscore addresses BYTES. The 68000 family is
	// big-endian, so an EVEN byte address is the HIGH half of the word --
	// consistent with maincpu.sv, where the low-byte write enable is driven
	// by !nLDS (lower data strobe = odd byte).
	wire [15:0] hs_word_addr = hs_address[16:1];
	wire        hs_byte_odd  = hs_address[0];

	// BOTH hiscore reads and writes go through the CPU port, and port B stays
	// tied off. Reading through port B instead looks free -- it is otherwise
	// unused -- but it is not: with b_addr constant Quartus collapses the
	// second read port, whereas driving it with a real address forces a true
	// dual-port with two independent read ports, which it can only implement
	// by REPLICATING the whole array. That took work RAM from 1Mbit to 2Mbit
	// (~102 extra M10K) and was why the design stopped fitting. Sharing port
	// A costs nothing here because hiscore only touches RAM with the CPU
	// paused (it asserts pause_cpu and waits ACCESS_PAUSEPAD cycles first).
	wire        hs_access       = hs_read | hs_write;
	wire [15:0] workram_a_addr  = hs_access ? hs_word_addr : workram_cpu_addr;
	wire        workram_a_wel   = hs_write ? hs_byte_odd  : workram_cpu_wel;
	wire        workram_a_weh   = hs_write ? ~hs_byte_odd : workram_cpu_weh;
	wire [15:0] workram_a_wdata = hs_write ? {hs_data_in, hs_data_in} : workram_cpu_wdata;

	logic [15:0] workram_unused_b;
	dpram #(.ADDR_WIDTH(16), .DATA_WIDTH(16)) u_workram (
		.clk(clk),
		.a_addr(workram_a_addr), .a_wel(workram_a_wel), .a_weh(workram_a_weh),
		.a_wdata(workram_a_wdata), .a_rdata(workram_cpu_rdata),
		.b_addr(16'd0), .b_rdata(workram_unused_b)
	);
	// The hiscore read byte is registered here, next to the RAM. The raw M10K
	// output otherwise has to reach the hiscore FSM's next-state logic on the
	// far side of the chip within one cycle -- that was the single worst
	// timing path in the design (~300 failing endpoints). hiscore.v is
	// patched for the extra cycle of read latency (SM_COMPAREHOLD and the
	// widened CHECK guards there); the CPU's own read path is untouched.
	always_ff @(posedge clk)
		hs_data_out <= hs_byte_odd ? workram_cpu_rdata[7:0] : workram_cpu_rdata[15:8];

	// ---- palette RAM: CPU write, compositor read ----
	logic [11:0] pal_addr;
	logic [15:0] pal_data;
	logic [11:0] pal_b_addr;
	logic [15:0] pal_b_rdata;
	dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_palette (
		.clk(clk),
		.a_addr(pal_cpu_addr), .a_wel(pal_cpu_wel), .a_weh(pal_cpu_weh),
		.a_wdata(pal_cpu_wdata), .a_rdata(pal_cpu_rdata),
		.b_addr(pal_b_addr), .b_rdata(pal_b_rdata)
	);
	// Palette dump: rows 48..63 carry all 4096 xRGB_555 entries, addressed as
	// {vcnt[3:0],hcnt[7:0]}. The compositor's read port is free while the
	// overlay is up because the picture is discarded that frame.
	wire        pal_dump_active = DEBUG_TRACER && dbg_overlay
								&& (vcnt >= 9'd48) && (vcnt < 9'd64);
	wire [11:0] pal_dump_addr   = {vcnt[3:0], hcnt[7:0]};

	// ---- sprite palette mirror ----
	// The compositor looks up the tile and the sprite palette entries in parallel every
	// pixel, so the sprite entries (0x000-0x3FF: 64 colours of 16) have a second copy, written
	// through with every CPU write to them. Sprites are composed a line after they render, so
	// they see the live palette, the same generation the tilemaps use.
	logic [9:0]  pal_s_addr;
	logic [15:0] pal_s_data;
	logic         comp_sprite_sel, comp_sprite_sel_d;
	logic         comp_backdrop_black, comp_backdrop_black_d;
	wire pal_mirror_hit = (pal_cpu_addr[11:10] == 2'd0);
	dpram #(.ADDR_WIDTH(10), .DATA_WIDTH(16)) u_palette_snap (
		.clk(clk),
		.a_addr(pal_cpu_addr[9:0]),
		.a_wel(pal_cpu_wel & pal_mirror_hit), .a_weh(pal_cpu_weh & pal_mirror_hit),
		.a_wdata(pal_cpu_wdata), .a_rdata(),
		.b_addr(pal_s_addr), .b_rdata(pal_s_data)
	);

	assign pal_b_addr = pal_dump_active ? pal_dump_addr : pal_addr;
	assign pal_data    = pal_b_rdata;

	// ---- tilemap VRAM: CPU write, per-layer tilemap engine read ----
	logic [11:0] l0_vram_addr;
	logic [15:0] l0_vram_data;
	logic [11:0] l1_vram_addr;
	logic [15:0] l1_vram_data;

	// ---- VRAM debug dump: borrow the tilemap engines' read ports ----
	// The overlay replaces the picture, so tilemap rendering is discarded that
	// frame and the layer engines' VRAM read ports are free. Indexing by
	// {vcnt[3:0],hcnt[7:0]} puts all 4096 words of both layers into 32
	// scanlines, so one screenshot carries the complete tilemap RAM for
	// comparison against a MAME dump. Touches no tilemap RTL.
	logic [11:0] vram0_b_addr, vram1_b_addr;
	logic [15:0] vram0_b_rdata, vram1_b_rdata;

	wire        vram_dump_active = DEBUG_TRACER && dbg_overlay && (vcnt < 9'd32);
	// vregs dump occupies rows 32..47: words 0x000-0xFFF of the video-register
	// region, which covers BOTH rowscroll tables (0x000-0x1FF) and the six
	// control/scroll registers (0x201..0x20B).
	logic [15:0] vregs_dump_data;
	wire         vregs_dump_active = DEBUG_TRACER && dbg_overlay
								   && (vcnt >= 9'd32) && (vcnt < 9'd48);
	wire [12:0] vregs_dump_addr   = {1'b0, vcnt[3:0], hcnt[7:0]};
	wire [11:0] vram_dump_addr   = {vcnt[3:0], hcnt[7:0]};

	assign vram0_b_addr = vram_dump_active ? vram_dump_addr : l0_vram_addr;
	assign vram1_b_addr = vram_dump_active ? vram_dump_addr : l1_vram_addr;
	assign l0_vram_data = vram0_b_rdata;
	assign l1_vram_data = vram1_b_rdata;

	dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_vram0 (
		.clk(clk),
		.a_addr(vram0_cpu_addr), .a_wel(vram0_cpu_wel), .a_weh(vram0_cpu_weh),
		.a_wdata(vram0_cpu_wdata), .a_rdata(vram0_cpu_rdata),
		.b_addr(vram0_b_addr), .b_rdata(vram0_b_rdata)
	);

`ifdef DEBUG_ISSP
	// JTAG READ probe for spriteram (instance "S") -- the debug-overlay VRAM
	// dump (l0/l1/vregs/palette) does not cover spriteram (no row budget
	// left in the 224-line overlay; see decode_vram.py), so sprite
	// attribute words are inspected over JTAG instead. Reads the
	// CPU-VISIBLE buffer (the one
	// spriteram_dbuf's cpu_addr/cpu_rdata port serves, i.e. the SAME
	// buffer MAME's own debugger/memory viewer shows -- not the render
	// engine's snapshot copy) so a probed value is directly comparable to
	// a MAME-side dump at the same word address, no double-buffering
	// translation needed.
	//
	// Read-only: the source address is an ordinary combinational select,
	// gated on effective_pause (with the CPU paused, spr_cpu_wel/weh are
	// naturally low, so overriding cpu_addr alone can't collide with a real
	// write). One register of read latency
	// (spriteram_dbuf's cpu_rdata is a normal synchronous BRAM output), so
	// the probe echoes effective_pause back too -- if it reads 0, the
	// returned data is whatever the LIVE game's own current address
	// happened to be, not the requested one.
	//
	// Usage (scripts/read_spriteram.tcl, word index 0-4095 -- attribute
	// table 0x000-0xBFF per docs/phase1_memory_map.md, display list
	// 0xC00-0xFFE, control word 0xFFF):
	//   quartus_stp -t scripts/read_spriteram.tcl <addr_hex>
	wire [11:0] dbg_spr_rd_addr;
	wire [11:0] spr_a_addr_muxed = effective_pause ? dbg_spr_rd_addr : spr_cpu_addr;

	altsource_probe #(
		.sld_auto_instance_index("YES"),
		.instance_id("S"),
		.probe_width(17),
		.source_width(12),
		.source_initial_value("0"),
		.enable_metastability("NO"),
		.lpm_type("altsource_probe")
	) u_issp_sprrd (
		.probe({effective_pause, spr_cpu_rdata}),
		.source(dbg_spr_rd_addr),
		.source_clk(clk),
		.source_ena(1'b1)
	);
`endif

	dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_vram1 (
		.clk(clk),
		.a_addr(vram1_cpu_addr), .a_wel(vram1_cpu_wel), .a_weh(vram1_cpu_weh),
		.a_wdata(vram1_cpu_wdata), .a_rdata(vram1_cpu_rdata),
		.b_addr(vram1_b_addr), .b_rdata(vram1_b_rdata)
	);

	// ---- vregs: CPU write, decoded per-layer control + row-scroll reads ----
	logic [7:0]  l0_rowscroll_addr, l1_rowscroll_addr;
	logic [15:0] l0_rowscroll_data, l1_rowscroll_data;
	logic [1:0]  l0_mode, l1_mode;
	logic [15:0] l0_base_x, l0_base_y, l1_base_x, l1_base_y;
	logic [1:0]  l0_bank, l1_bank;
	logic         l0_rs_en, l1_rs_en;
	logic         l0_rs_pertile, l1_rs_pertile;

	vreg_decode u_vregs (
		.clk(clk), .reset(reset),
		.cpu_addr(vregs_cpu_addr), .cpu_wel(vregs_cpu_wel), .cpu_weh(vregs_cpu_weh),
		.cpu_wdata(vregs_cpu_wdata), .cpu_rdata(vregs_cpu_rdata),
		.layer0_rowscroll_addr(l0_rowscroll_addr), .layer0_rowscroll_data(l0_rowscroll_data),
		.layer1_rowscroll_addr(l1_rowscroll_addr), .layer1_rowscroll_data(l1_rowscroll_data),
		.layer0_mode(l0_mode), .layer0_base_x_scroll(l0_base_x), .layer0_base_y_scroll(l0_base_y),
		.layer0_bank(l0_bank),
		.layer0_rowscroll_enable(l0_rs_en), .layer0_rowscroll_pertile(l0_rs_pertile),
		.layer1_mode(l1_mode), .layer1_base_x_scroll(l1_base_x), .layer1_base_y_scroll(l1_base_y),
		.layer1_bank(l1_bank),
		.layer1_rowscroll_enable(l1_rs_en), .layer1_rowscroll_pertile(l1_rs_pertile),
		.dbg_dump_en(vregs_dump_active), .dbg_dump_addr(vregs_dump_addr),
		.dbg_dump_data(vregs_dump_data)
	);

	// ---- tilemap engines ----
	// dreamwld.cpp screen_update: scrolly + 32 on both layers, scrollx + 0 on layer 0 and + 2
	// on layer 1.

	logic         l0_pixel_valid, l1_pixel_valid;
	logic [3:0]  l0_pixel_index, l1_pixel_index;
	logic [6:0]  l0_pixel_color, l1_pixel_color;
	logic         l0_fetch_overrun, l1_fetch_overrun; // echoed in the debug overlay control band
	logic         l0_overrun_ev, l1_overrun_ev;     // per-event pulses, counted below

	tilemap_line_engine #(.LAYER(0)) u_layer0 (
		.clk(clk), .reset(reset),
		.vcnt(vcnt_next_active), .ce_pix(ce_pix), .h_active(h_active), .line_start(line_start),
		.mode(l0_mode), .base_x_scroll(l0_base_x), .base_y_scroll(l0_base_y + 16'd32), .bank(l0_bank),
		.rowscroll_enable(l0_rs_en), .rowscroll_pertile(l0_rs_pertile), .flip(flip_screen),
		.rowscroll_addr(l0_rowscroll_addr), .rowscroll_data(l0_rowscroll_data),
		.vram_addr(l0_vram_addr), .vram_data(l0_vram_data),
		.gfxrom_req(l0_gfxrom_req), .gfxrom_addr(l0_gfxrom_addr),
		.gfxrom_valid(l0_gfxrom_valid), .gfxrom_data(l0_gfxrom_data),
		.pixel_valid(l0_pixel_valid), .pixel_index(l0_pixel_index), .pixel_color(l0_pixel_color),
		.fetch_overrun(l0_fetch_overrun), .overrun_ev(l0_overrun_ev)
	);

	tilemap_line_engine #(.LAYER(1)) u_layer1 (
		.clk(clk), .reset(reset),
		.vcnt(vcnt_next_active), .ce_pix(ce_pix), .h_active(h_active), .line_start(line_start),
		.mode(l1_mode), .base_x_scroll(l1_base_x + 16'd2), .base_y_scroll(l1_base_y + 16'd32), .bank(l1_bank),
		.rowscroll_enable(l1_rs_en), .rowscroll_pertile(l1_rs_pertile), .flip(flip_screen),
		.rowscroll_addr(l1_rowscroll_addr), .rowscroll_data(l1_rowscroll_data),
		.vram_addr(l1_vram_addr), .vram_data(l1_vram_data),
		.gfxrom_req(l1_gfxrom_req), .gfxrom_addr(l1_gfxrom_addr),
		.gfxrom_valid(l1_gfxrom_valid), .gfxrom_data(l1_gfxrom_data),
		.pixel_valid(l1_pixel_valid), .pixel_index(l1_pixel_index), .pixel_color(l1_pixel_color),
		.fetch_overrun(l1_fetch_overrun), .overrun_ev(l1_overrun_ev)
	);

	// ---- sprite RAM, its vblank copy, and the per-frame list ----
	// dreamwld.cpp screen_vblank copies sprite RAM at vblank start and the next frame is drawn
	// from that copy. Here the copy starts at frame_start and the list is built from it once
	// it is complete (2048 + ~4.6K clk, well inside vblank); the 68020's sprite RAM writes wait
	// for the copy (maincpu spr_hold).
	logic [11:0] at_addr;
	logic [15:0] at_data;
	logic         spr_copy_busy_d;

	spriteram_dbuf u_spriteram (
		.clk(clk), .reset(reset), .copy_start(frame_start), .copy_busy(spr_copy_busy),
`ifdef DEBUG_ISSP
		.cpu_addr(spr_a_addr_muxed),
`else
		.cpu_addr(spr_cpu_addr),
`endif
		.cpu_wel(spr_cpu_wel), .cpu_weh(spr_cpu_weh),
		.cpu_wdata(spr_cpu_wdata), .cpu_rdata(spr_cpu_rdata),
		.at_addr(at_addr), .at_data(at_data)
	);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) spr_copy_busy_d <= 1'b0;
		else        spr_copy_busy_d <= spr_copy_busy;
	end

	logic build_busy, build_done;
	wire  build_start = spr_copy_busy_d & ~spr_copy_busy;

	logic [9:0]  sl_scan_addr, sl_rec_addr;
	logic [17:0] sl_scan_ytest;
	logic [63:0] sl_rec_data;
	logic [10:0] sl_count;

	sprite_line_list u_sprite_list (
		.clk(clk), .reset(reset),
		.build_start(build_start), .build_busy(build_busy), .build_done(build_done),
		.at_addr(at_addr), .at_data(at_data),
		.scan_addr(sl_scan_addr), .scan_ytest(sl_scan_ytest),
		.rec_addr(sl_rec_addr), .rec_data(sl_rec_data),
		.count(sl_count)
	);

	// ---- per-scanline sprite render + double-buffered line buffer ----
	// The engine renders the NEXT visible line (vcnt_next_active, the same
	// next-line convention the tilemap engines prefetch with) while the line
	// buffer's other bank scans out the current one. line_start doubles as
	// the hard resync: an engine still busy at the boundary aborts (writes
	// stop that cycle), drains any in-flight SDRAM handshake during the
	// buffer's 320-cycle clear, and the clipped line is counted. The render
	// start fires when the clear completes, provided the next line is
	// visible and neither the table build nor the snapshot copy is running.
	logic le_busy, le_ovr_ev, lb_ready, lb_ready_d;
	always_ff @(posedge clk or posedge reset) begin
		if (reset) lb_ready_d <= 1'b0;
		else        lb_ready_d <= lb_ready;
	end

	// Gates on the line the engine is ABOUT TO RENDER, which is vcnt+2 (see
	// video_timing's vcnt_next2_active). vcnt 0..221 -> rows 2..223; vcnt 261
	// and 262 (V total 263) wrap to rows 0 and 1. Everything between renders a
	// row that is not displayed, so it is skipped.
	wire next_line_visible = (vcnt < 9'd222) || (vcnt >= 9'd261);
	wire le_start = lb_ready & ~lb_ready_d & next_line_visible
	              & ~build_busy & ~spr_copy_busy;

	logic         le_fb_we;
	logic [8:0]  le_fb_x;
	logic [3:0]  le_fb_pixel;
	logic [5:0]  le_fb_color;

	sprite_line_engine u_sprite_line (
		.clk(clk), .reset(reset),
		.line_tick(line_start), .line_start(le_start),
		// flipped: render the source line the screen line mirrors
		.render_line(flip_screen ? 8'd223 - vcnt_next2_active : vcnt_next2_active),
		.busy(le_busy), .ovr_ev(le_ovr_ev),
		.scan_addr(sl_scan_addr), .scan_ytest(sl_scan_ytest),
		.rec_addr(sl_rec_addr), .rec_data(sl_rec_data), .count(sl_count),
		.lut_req(sp_lut_req), .lut_addr(sp_lut_addr), .lut_valid(sp_lut_valid), .lut_data(sp_lut_data),
		.gfxrom_req(sp_gfxrom_req), .gfxrom_addr(sp_gfxrom_addr),
		.gfxrom_valid(sp_gfxrom_valid), .gfxrom_data(sp_gfxrom_data),
		.fb_we(le_fb_we), .fb_x(le_fb_x),
		.fb_pixel(le_fb_pixel), .fb_color(le_fb_color)
	);

	logic         sp_present;
	logic [3:0]  sp_pixel;
	logic [5:0]  sp_color;

	sprite_line_buffer u_sprite_linebuf (
		.clk(clk), .reset(reset),
		.line_start(line_start), .ready(lb_ready),
		.we(le_fb_we), .wx(le_fb_x),
		.wpixel(le_fb_pixel), .wcolor(le_fb_color),
		// flipped: read the line right to left. Outside the active window
		// the read is never displayed; hold it in range.
		// screen x = hcnt - 1 (video_timing)
		.rx(hcnt == 9'd0 || hcnt > 9'd308 ? 9'd0 : !flip_screen ? hcnt - 9'd1 : 9'd308 - hcnt),
		.rd_present(sp_present), .rd_pixel(sp_pixel), .rd_color(sp_color)
	);

	// ---- instrumentation ----
	// Rates, not flags: sticky bits saturate within seconds of boot and only
	// answer "has this ever happened" when the question is "does this happen
	// under load". sp_ovr_cnt counts LINES the hard resync clipped;
	// sp_render_max is the worst per-line render time in clk cycles (budget:
	// 3,552 at 54 MHz, minus the 320-cycle clear). Read against ovr_frames (row 220).
	logic [19:0] l0_ovr_cnt = '0, l1_ovr_cnt = '0, sp_ovr_cnt = '0, ovr_frames = '0;

	always_ff @(posedge clk) begin
		if (l0_overrun_ev) l0_ovr_cnt <= l0_ovr_cnt + 1'b1;
		if (l1_overrun_ev) l1_ovr_cnt <= l1_ovr_cnt + 1'b1;
		if (le_ovr_ev)      sp_ovr_cnt <= sp_ovr_cnt + 1'b1;
		if (frame_start)    ovr_frames <= ovr_frames + 1'b1;
	end

	logic sp_overran = 1'b0;   // sticky: any line ever clipped by the resync
	logic [19:0] sp_line_cycles = '0;
	logic [19:0] sp_render_max  = '0;
	always_ff @(posedge clk) begin
		if (le_ovr_ev) sp_overran <= 1'b1;
		if (line_start)    sp_line_cycles <= '0;
		else if (le_busy) sp_line_cycles <= sp_line_cycles + 1'b1;
		if (line_start && (sp_line_cycles > sp_render_max))
			sp_render_max <= sp_line_cycles;
	end

	// ---- compositor ----
	compositor u_compositor (
		.l0_valid(l0_pixel_valid), .l0_pixel(l0_pixel_index), .l0_color(l0_pixel_color),
		.l0_enable(~dbg_render_dis[1]),
		.l1_valid(l1_pixel_valid), .l1_pixel(l1_pixel_index), .l1_color(l1_pixel_color),
		.l1_enable(~dbg_render_dis[2]),
		.sp_present(sp_present & ~dbg_render_dis[0]), .sp_pixel(sp_pixel), .sp_color(sp_color),
		.pal_addr(pal_addr), .pal_s_addr(pal_s_addr), .sprite_sel(comp_sprite_sel),
		.backdrop_black(comp_backdrop_black)
	);

	// Final RGB mux: both palette RAMs are read in parallel and answer a cycle after the
	// compositor chose, so its selects are registered to match. A sprite is drawn over
	// anything, including the black of an undrawn tile pixel.
	always_ff @(posedge clk) begin
		comp_sprite_sel_d    <= comp_sprite_sel;
		comp_backdrop_black_d <= comp_backdrop_black;
	end
	assign rgb = comp_sprite_sel_d ? pal_s_data[14:0]
			   : comp_backdrop_black_d ? 15'd0
			   : pal_data[14:0];


	// ---- debug tracer (two buffers, no source selection) ------------------
	// Deliberately NOT selectable at runtime. The OSD source-select bit was
	// tried at status[50:49] and again at status[58:57] and never took effect
	// (the overlay bit in the same byte works, so the CFG path itself is
	// fine). Rather than debug that a third time, both signals of interest
	// are captured simultaneously into separate buffers and read out by
	// scanline:
	//   scanlines   0-127 : CPU ROM read, FULL 19-bit word address
	//   scanlines 128-255 : CPU ROM read, {addr[7:0], data} -- SAME event N
	// Both buffers are strobed by cpu_rom_valid, so entry N of one describes
	// exactly the same bus cycle as entry N of the other: scanline L and
	// scanline L+128 are one read, seen twice.
	//
	// Why the full address is worth a whole buffer: capturing only addr[7:0]
	// cannot distinguish a CPU that is genuinely sweeping ROM (a checksum,
	// address climbing, low bits wrapping every 256 words) from a ROM read
	// path that ALIASES (upper address bits dropped, so word 2048 returns
	// word 0). Those two have completely different causes and the truncated
	// capture looks identical for both. The sprite-write tracer is dropped
	// for this build: sprite writes were already confirmed present, and this
	// question gates everything downstream of it.
	generate if (DEBUG_TRACER) begin : g_tracer
		logic [23:0] rd_addr, rd_data;
		logic        frz_a, frz_d;

		// TRIGGER: word address 8 is bytes 0x10-0x13 = exception vector 4,
		// Illegal Instruction. On hardware the CPU fetches this vector over and
		// over in an 8-read loop, so freezing on the FIRST fetch leaves the
		// buffer holding the 127 ROM reads that preceded it -- the code that
		// caused the exception. MAME's boot never executes any of the loop's
		// addresses, so this is a fault path, not game logic.
		wire trig_vec4 = (cpu_rom_addr == 20'd8);

		// dbg_src[0] = ring (latest N) vs first-N + window walk
		// dbg_src[1] = freeze on trigger
		debug_tracer #(.DEPTH(128), .WIDTH(24)) u_trace_addr (
			.clk(clk),
			.cap_stb(cpu_rom_valid),
			.cap_data({4'd0, cpu_rom_addr}),
			.ctl_rearm(dbg_rearm),
			.ctl_window(dbg_window),
			.ctl_ring(dbg_src[0]),
			.ctl_trig_en(dbg_src[1]),
			.cap_trig(trig_vec4),
			.rd_index(vcnt - 9'd64),
			.rd_data(rd_addr),
			.frozen(frz_a)
		);

		debug_tracer #(.DEPTH(128), .WIDTH(24)) u_trace_data (
			.clk(clk),
			.cap_stb(cpu_rom_valid),
			.cap_data({cpu_rom_addr[7:0], cpu_rom_data}),
			.ctl_rearm(dbg_rearm),
			.ctl_window(dbg_window),
			.ctl_ring(dbg_src[0]),
			.ctl_trig_en(dbg_src[1]),
			.cap_trig(trig_vec4),
			.rd_index(vcnt - 9'd192),
			.rd_data(rd_data),
			.frozen(frz_d)
		);

		// Scanlines 216-223 echo the CONTROL INPUTS back out, plus a fixed 0xA5
		// marker byte so a mis-decoded band is obvious rather than silently
		// believable.
		//
		// This exists because three separate captures at ctl_window = 0, 1 and 8
		// returned byte-identical images, which is impossible if the window is
		// reaching the tracer (the skip step is 8191, prime -- no event period
		// can alias with all three). Rather than keep debugging the consequence
		// while assuming the control input is correct, the core now reports what
		// it actually receives. If this band reads back window=0 while the CFG
		// holds window=8, the fault is in the OSD/status path, not the tracer.
		// (The low bit is a constant 1, giving a second fixed bit alongside
		// the 0xA5 marker to catch a mis-decoded band.)
		// Middle byte carries the video-engine health flags. l0/l1_fetch_overrun
		// are STICKY: set once a tilemap line engine wanted to display a pixel
		// whose tile had not been fetched yet, which makes it drop pixel_valid
		// -- and the compositor then silently paints backdrop. Without this
		// readout, a tilemap that cannot keep up is visually identical to the
		// game legitimately drawing nothing there, so a large flat backdrop
		// area is unattributable. The layer enables sit next to them because
		// "no pixels" also happens when a layer is simply switched off, and
		// those two causes need telling apart.
		wire [23:0] ctl_echo = {8'hA5,
								sp_overran, 1'd0, l0_fetch_overrun, l1_fetch_overrun,
								~dbg_render_dis[1], ~dbg_render_dis[2], frz_a, frz_d,
								dbg_rearm, dbg_window, dbg_src, 1'b1};

		// Overlay band layout (one screenshot carries all of it):
		//   rows   0- 15 : layer 0 VRAM, all 4096 words  ({vcnt[3:0],hcnt[7:0]})
		//   rows  16- 31 : layer 1 VRAM, all 4096 words
		//   rows  32- 47 : video registers, words 0x000-0xFFF
		//   rows  48-175 : CPU ROM read, full 19-bit address (128 entries)
		//   rows 176-214 : CPU ROM read, {addr[7:0],data}    (39 entries)
		//   row  215 : worst-case sprite render length, in clk cycles
		//   rows 216, 221-223 : control echo + video-engine health flags
		//   row  217 : layer-0 fetch-overrun COUNT   row 218 : layer-1 ditto
		//   row  219 : sprite render-overrun COUNT   row 220 : frames elapsed
		//              (two captures a known time apart give a per-frame rate)
		//   rows  48- 63 : palette RAM, all 4096 xRGB_555 entries
		assign dbg_pixel = (vcnt == 9'd215) ? {4'd0, sp_render_max}
						 : (vcnt == 9'd217) ? {4'd0, l0_ovr_cnt}
						 : (vcnt == 9'd218) ? {4'd0, l1_ovr_cnt}
						 : (vcnt == 9'd219) ? {4'd0, sp_ovr_cnt}
						 : (vcnt == 9'd220) ? {4'd0, ovr_frames}
						 : (vcnt >= 9'd216) ? ctl_echo
						 : (vcnt <  9'd16)  ? {8'h00, vram0_b_rdata}
						 : (vcnt <  9'd32)  ? {8'h00, vram1_b_rdata}
						 : (vcnt <  9'd48)  ? {8'h00, vregs_dump_data}
						 : (vcnt <  9'd64)  ? {8'h00, pal_b_rdata}
						 : (vcnt <  9'd192) ? rd_addr
											: rd_data;
	end else begin : g_no_tracer
		assign dbg_pixel = 24'd0;
	end endgenerate

endmodule
