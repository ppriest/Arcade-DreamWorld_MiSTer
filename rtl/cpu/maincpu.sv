// Main CPU: 68EC020 at 16 MHz (dreamwld.cpp baryon(): XTAL 32MHz/2, "16MHz
// verified"). Drives the vendored TG68KdotC_Kernel directly (rtl/cpu/tg68k/,
// PROVENANCE.md; every kernel signal needs an explicit zero initializer,
// github.com/TobiFlex/TG68K.C/issues/21), plus address decode, BRAM-region
// ports and the held, autovectored level-4 vblank IRQ (irq4_line_hold).
//
// The decode is dreamwld.cpp's baryon_map and dreamwld_map (lines 417-447). Program
// ROM (0x000000-0x1FFFFF, 2 MB) is req/valid; the BRAM regions (sprite RAM, palette,
// tilemap VRAM x2, row-scroll RAM and video regs, work RAM) are synchronous with one
// cycle of read latency. Unmapped reads return 0, MAME's default for a map without
// unmap_value_high.
//
// The 68EC020 has a 32-bit bus in MAME; TG68K's here is 16 bits, so a long access is two
// word cycles. Each I/O handler below fires on the word MAME's handler lives on, so a
// long access to it fires once; the games use byte accesses there (docs/boot_trace_mame.txt).
//
// Verified in the Psikyo core by sim/maincpu_tb/tb_maincpu.sv: real ROM
// req/valid fetch, all 6 BRAM regions, the 32-bit input-port read, and the
// vblank IRQ (keep the vector table real when extending that bench: a zeroed
// one once made the IRQ look like a CPU fault).
//
// IPL: the kernel inverts its IPL input (`IPL_nr <= NOT IPL`), so level 4 is
// requested by driving 3'b011, not 3'b100.

module maincpu #(
	// MAME's spin_until_time(50 us) after each MCU handshake access: 50 us at 54 MHz
	parameter int STALL_CLKS = 2700
) (
	input  logic clk,
	input  logic reset,

	// program ROM, req/valid -- WORD address into the 2 MB region
	output logic         rom_req,
	output logic [19:0] rom_addr,
	input  logic         rom_valid,
	input  logic [15:0] rom_data,

	// sprite RAM (0x400000-0x401FFF, 4096 words), 1-cycle sync BRAM port
	output logic [11:0] spriteram_addr,
	output logic         spriteram_wel, spriteram_weh,
	output logic [15:0] spriteram_wdata,
	input  logic [15:0] spriteram_rdata,

	// palette RAM (0x600000-0x601FFF, 4096 words)
	output logic [11:0] palette_addr,
	output logic         palette_wel, palette_weh,
	output logic [15:0] palette_wdata,
	input  logic [15:0] palette_rdata,

	// tilemap layer 0 VRAM (0x800000-0x801FFF, 4096 words)
	output logic [11:0] vram0_addr,
	output logic         vram0_wel, vram0_weh,
	output logic [15:0] vram0_wdata,
	input  logic [15:0] vram0_rdata,

	// tilemap layer 1 VRAM (0x802000-0x803FFF, 4096 words)
	output logic [11:0] vram1_addr,
	output logic         vram1_wel, vram1_weh,
	output logic [15:0] vram1_wdata,
	input  logic [15:0] vram1_rdata,

	// row-scroll RAM and video regs (0x804000-0x805FFF)
	output logic [12:0] vregs_addr,
	output logic         vregs_wel, vregs_weh,
	output logic [15:0] vregs_wdata,
	input  logic [15:0] vregs_rdata,

	// work RAM (0xFE0000-0xFFFFFF, 65536 words)
	output logic [15:0] workram_addr,
	output logic         workram_wel, workram_weh,
	output logic [15:0] workram_wdata,
	input  logic [15:0] workram_rdata,

	// input ports (read-only, raw values -- caller owns debouncing/mapping)
	input  logic [31:0] p1p2_in,     // 0xC00000-0xC00003
	input  logic [31:0] dsw_in,      // 0xC00004-0xC00007

	// OKI M6295 x2 (0xC00018 / 0xC00028, upper byte lane) and their bank registers
	// (0xC0000F / 0xC0002F, lower lane). oki2 exists on the dreamwld_map sets only.
	input  logic         has_oki2,
	output logic         oki1_wr, oki2_wr,       // pulse: command byte in oki_wdata
	output logic [7:0]  oki_wdata,
	input  logic [7:0]  oki1_dout, oki2_dout,
	output logic         oki1_bank_we, oki2_bank_we,
	output logic [1:0]  oki_bank,

	// protection MCU (rtl/mcu/semicom_mcu.sv)
	output logic         prot_wr,         // pulse: write to 0xC00020
	output logic         prot_rd,         // pulse: read of 0xC00030
	input  logic [7:0]  prot_latch,       // returned in bits 31:24 at 0xC00030

	// Freeze the CPU (debug). Gates the 16 MHz clock enable, so the 68020
	// simply stops stepping; video timing and the debug overlay keep running,
	// which is what makes a frame comparable against a MAME dump.
	input  logic         pause,

	// Sprite RAM is being copied for the next frame (spriteram_dbuf): a sprite RAM write
	// waits, uncommitted, until it ends. MAME's copy takes no time.
	input  logic         spr_hold,

	// vblank IRQ (level 4, held/autovectored -- see header)
	input  logic         vblank
);

	// =====================================================================
	// CPU: TG68KdotC_Kernel driven DIRECTLY, at a 16 MHz clock enable.
	//
	// This module used to instantiate the TG68K.vhd WRAPPER. That wrapper is
	// an async-68000-BUS ADAPTER, not the CPU: it emulates real 68000 bus
	// phases (AS/UDS/LDS/DTACK) and therefore contains falling-edge
	// registers, and it assumes CLK *is* the CPU clock. Rate-limiting it to
	// 16 MHz meant fighting its design -- see docs/LESSONS_LEARNED.md and
	// docs/LESSONS_LEARNED.md ("TG68K.C") for the chain of failures that caused.
	//
	// The kernel underneath is entirely rising-edge and exposes clkena_in
	// for exactly this purpose. Established cores drive it directly and own
	// the bus interface themselves; mist-devel/plus_too's tg68k.v is the
	// reference. Its interface is synchronous and far simpler:
	//
	//   busstate: 00 fetch code, 10 read data, 11 write data, 01 no access
	//   data_in / data_write are SEPARATE ports -- no bidirectional DATA net
	//
	// Consequences, all of which delete code that existed only to serve the
	// wrapper: no DATA tri-state, no AS/UDS/LDS phase emulation, no DTACK
	// handshake, and no VPA/E-clock autovector games (IPL_autovector is
	// simply tied high). It also removes the need for any CPU
	// set_multicycle_path in DreamWorld.sdc -- an all-rising-edge kernel gated
	// by a real clock enable has no half-cycle paths to mis-constrain.
	// =====================================================================

	// ---- 16 MHz CPU clock enable ----
	// The board clocks the 68EC020 at 32MHz/2 = 16 MHz (dreamwld.cpp
	// baryon(), "16MHz verified"). clk_sys is 54 MHz, so the enable rate is
	// exactly 16/54 = 8/27 -- a Bresenham accumulator with zero error. Ticks
	// land 3 or 4 clk_sys cycles apart (DreamWorld.sdc's multicycles depend
	// on that minimum).
	localparam int CE_NUM = 8;     // 16 MHz
	localparam int CE_DEN = 27;    // 54 MHz

	logic [10:0] ce_acc;
	logic        cpu_ce;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			ce_acc <= 11'd0;
			cpu_ce <= 1'b0;
		end else if (pause) begin
			cpu_ce <= 1'b0;
		end else if (ce_acc + CE_NUM >= CE_DEN) begin
			ce_acc <= 11'(ce_acc + CE_NUM - CE_DEN);
			cpu_ce <= 1'b1;
		end else begin
			ce_acc <= 11'(ce_acc + CE_NUM);
			cpu_ce <= 1'b0;
		end
	end

	// ---- kernel instance ----
	logic [31:0] a32;
	logic [15:0] cpu_din, cpu_dout;
	logic [1:0]  busstate;
	logic        nWr, nUDS, nLDS;
	logic [2:0]  fc;
	logic [2:0]  ipl;
	logic        cpu_clkena;

	TG68KdotC_Kernel #(
		.SR_Read(2), .VBR_Stackframe(2), .extAddr_Mode(2),
		.MUL_Mode(2), .DIV_Mode(2), .BitField(2),
		.BarrelShifter(0), .MUL_Hardware(1)
	) u_cpu (
		.clk(clk),
		.nReset(~reset),
		.clkena_in(cpu_clkena),
		.data_in(cpu_din),
		.IPL(ipl),
		.IPL_autovector(1'b1),   // the level-4 vblank IRQ is autovectored
		.berr(1'b0),             // active HIGH in the kernel; no bus errors here
		.CPU(2'b11),             // 68020
		.addr_out(a32),
		.data_write(cpu_dout),
		.nWr(nWr), .nUDS(nUDS), .nLDS(nLDS),
		.busstate(busstate),
		.longword(),
		.nResetOut(),
		.FC(fc),
		.clr_berr(),
		.skipFetch(),
		.regin_out(), .CACR_out(), .VBR_out()
	);

	// ---- address decode (unchanged from the previous implementation) ----
	logic [23:0] addr24;
	assign addr24 = a32[23:0];

	logic is_rom, is_spriteram, is_palette, is_vram0, is_vram1, is_vregs, is_workram;
	logic is_p1p2, is_dsw;

	assign is_rom        = (addr24 <= 24'h1FFFFF);
	assign is_spriteram  = (addr24 >= 24'h400000) && (addr24 <= 24'h401FFF);
	assign is_palette    = (addr24 >= 24'h600000) && (addr24 <= 24'h601FFF);
	assign is_vram0      = (addr24 >= 24'h800000) && (addr24 <= 24'h801FFF);
	assign is_vram1      = (addr24 >= 24'h802000) && (addr24 <= 24'h803FFF);
	assign is_vregs      = (addr24 >= 24'h804000) && (addr24 <= 24'h805FFF);
	assign is_workram    = (addr24 >= 24'hFE0000) && (addr24 <= 24'hFFFFFF);

	assign is_p1p2       = (addr24 >= 24'hC00000) && (addr24 <= 24'hC00003);
	assign is_dsw        = (addr24 >= 24'hC00004) && (addr24 <= 24'hC00007);

	// I/O words, 0xC00000-0xC0003F (word index addr24[5:1])
	wire       is_io      = (addr24[23:6] == 18'h30000);
	wire [4:0] io_word    = addr24[5:1];
	wire is_oki1_bank = is_io && io_word == 5'd7;               // 0xC0000F
	wire is_oki1      = is_io && io_word == 5'd12;              // 0xC00018
	wire is_prot_w    = is_io && io_word == 5'd16;              // 0xC00020
	wire is_oki2      = is_io && io_word == 5'd20 && has_oki2;  // 0xC00028
	wire is_oki2_bank = is_io && io_word == 5'd23 && has_oki2;  // 0xC0002F
	wire is_prot_r    = is_io && io_word == 5'd24;              // 0xC00030 (0xC00032 reads 0)

	// word-address translation (drop bit 0 -- every region is word-granular)
	assign rom_addr       = a32[20:1];
	assign spriteram_addr = a32[12:1];
	assign palette_addr   = a32[12:1];
	assign vram0_addr     = a32[12:1];
	assign vram1_addr     = a32[12:1];
	assign vregs_addr     = a32[13:1];
	assign workram_addr   = a32[16:1];

	// ---- bus access state ----
	// The CPU is stalled purely by holding cpu_clkena low; there is no DTACK.
	// acc_ready is a LEVEL, not a pulse, so it cannot be missed by the 16 MHz
	// enable the way a one-cycle valid could -- the CPU simply advances on the
	// first cpu_ce tick after the access completes.
	logic        acc_ready;
	logic [15:0] acc_data;

	// Settle/latency phase counter. The CPU's address (a32) is a registered
	// kernel output that changes on a cpu_ce tick, but its downstream path
	// measures ~14 ns -- longer than one 11.64 ns clock -- so it is NOT
	// settled during the first cycle after a step. Acting in that cycle
	// would commit a BRAM write to a half-settled ADDRESS, which repeating
	// the write later does not undo.
	//   acc_ph == 0 : address still settling, do nothing
	//   acc_ph == 1 : address settled -> commit writes here
	//   acc_ph == 2 : BRAM has output data for the settled address -> capture
	// (BRAM registers its address each edge and returns data one cycle
	// later, so the first output that corresponds to a settled address
	// appears at phase 2.)
	logic [1:0]  acc_ph;

	wire mem_needed = (busstate != 2'b01);
	wire is_write   = (busstate == 2'b11);

	assign cpu_clkena = cpu_ce && (!mem_needed || acc_ready);

	// ROM req is a ONE-CYCLE PULSE, not a held level.
	//
	// rtl/memory/sdram_narrow_bridge.sv latches the request in B_IDLE
	// (`if (req) begin word_sel <= addr[2:1]; bstate <= B_WAIT; end`) and
	// returns to B_IDLE once g_valid arrives. If req is still asserted then,
	// it immediately re-enters B_WAIT and issues ANOTHER granule read, and
	// keeps doing so until req drops -- burning SDRAM bandwidth and making
	// cpu_rom_valid pulse repeatedly for a single CPU access.
	//
	// The bridge's own state machine is the authority on the req shape,
	// and it wants a PULSE -- not held-until-acknowledged (sdram_arbiter5.sv
	// documents a different contract for its own port; it does not apply
	// here).
	logic rom_req_sent;
	assign rom_req = mem_needed && !is_write && is_rom && !acc_ready && !rom_req_sent;

	// ---- read mux (BRAM + input ports; ROM comes via rom_data) ----
	logic [15:0] read_mux;
	always_comb begin
		if      (is_spriteram) read_mux = spriteram_rdata;
		else if (is_palette)   read_mux = palette_rdata;
		else if (is_vram0)     read_mux = vram0_rdata;
		else if (is_vram1)     read_mux = vram1_rdata;
		else if (is_vregs)     read_mux = vregs_rdata;
		else if (is_workram)   read_mux = workram_rdata;
		else if (is_p1p2)      read_mux = a32[1] ? p1p2_in[15:0] : p1p2_in[31:16];
		else if (is_dsw)       read_mux = a32[1] ? dsw_in[15:0]  : dsw_in[31:16];
		else if (is_oki1)      read_mux = {oki1_dout, 8'h00};
		else if (is_oki2)      read_mux = {oki2_dout, 8'h00};
		else if (is_prot_r)    read_mux = {prot_latch, 8'h00};
		else                   read_mux = 16'h0000;   // unmapped
	end

	// MCU handshake accesses hold the bus STALL_CLKS after they complete, as MAME spins
	// the 68020 50 us in to_prot_w and protdata_r ("give it time to respond"); the 68020
	// code does not poll. The read value is taken when the access completes, as MAME's.
	wire stall_acc = (is_prot_w && is_write) || (is_prot_r && !is_write);
	wire spr_wr_hold = is_spriteram && is_write && spr_hold;
	logic        stall_run;
	logic [11:0] stall_cnt;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			acc_ready    <= 1'b0;
			acc_data     <= 16'h0000;
			acc_ph       <= 2'd0;
			rom_req_sent <= 1'b0;
			stall_run    <= 1'b0;
			stall_cnt    <= 12'd0;
		end else if (cpu_clkena) begin
			// CPU has consumed this access; arm for the next one
			acc_ready    <= 1'b0;
			acc_ph       <= 2'd0;
			rom_req_sent <= 1'b0;
			stall_run    <= 1'b0;
		end else if (mem_needed && !acc_ready && !spr_wr_hold) begin
			if (rom_req) rom_req_sent <= 1'b1;   // one pulse per access
			if (acc_ph != 2'd3) acc_ph <= acc_ph + 2'd1;
			if (is_rom && !is_write) begin
				// SDRAM latency dominates; rom_req is held until valid
				if (rom_valid) begin
					acc_data  <= rom_data;
					acc_ready <= 1'b1;
				end
			end else begin
				// writes commit at phase 1, reads capture at phase 2
				if (!is_write && acc_ph == 2'd2) acc_data <= read_mux;
				if (is_write ? (acc_ph >= 2'd1) : (acc_ph >= 2'd2)) begin
					if (!stall_acc) begin
						acc_ready <= 1'b1;
					end else if (!stall_run) begin
						stall_run <= 1'b1;
						stall_cnt <= 12'(STALL_CLKS - 1);
					end else if (stall_cnt == 12'd0) begin
						acc_ready <= 1'b1;
					end else begin
						stall_cnt <= stall_cnt - 12'd1;
					end
				end
			end
		end
	end

	assign cpu_din = acc_data;   // registered and stable -- never combinational

	// ---- writes ----
	// Held for exactly the cycle at which the address is settled and the
	// access completes (acc_ph == 1) -- see acc_ph's comment. One cycle is
	// all a synchronous BRAM port needs.
	wire wr_now = mem_needed && is_write && !acc_ready && (acc_ph == 2'd1) && !spr_wr_hold;

	assign spriteram_wel   = wr_now && is_spriteram && !nLDS;
	assign spriteram_weh   = wr_now && is_spriteram && !nUDS;
	assign spriteram_wdata = cpu_dout;

	assign palette_wel   = wr_now && is_palette && !nLDS;
	assign palette_weh   = wr_now && is_palette && !nUDS;
	assign palette_wdata = cpu_dout;

	assign vram0_wel   = wr_now && is_vram0 && !nLDS;
	assign vram0_weh   = wr_now && is_vram0 && !nUDS;
	assign vram0_wdata = cpu_dout;

	assign vram1_wel   = wr_now && is_vram1 && !nLDS;
	assign vram1_weh   = wr_now && is_vram1 && !nUDS;
	assign vram1_wdata = cpu_dout;

	assign vregs_wel   = wr_now && is_vregs && !nLDS;
	assign vregs_weh   = wr_now && is_vregs && !nUDS;
	assign vregs_wdata = cpu_dout;

	assign workram_wel   = wr_now && is_workram && !nLDS;
	assign workram_weh   = wr_now && is_workram && !nUDS;
	assign workram_wdata = cpu_dout;

	// I/O writes. Byte handlers in MAME: the OKIs on the even byte (upper lane), the bank
	// registers on the odd byte (lower lane). 0xC00010 ("might reset the MCU") is not
	// modelled, as in MAME.
	assign oki1_wr      = wr_now && is_oki1 && !nUDS;
	assign oki2_wr      = wr_now && is_oki2 && !nUDS;
	assign oki_wdata    = cpu_dout[15:8];
	assign oki1_bank_we = wr_now && is_oki1_bank && !nLDS;
	assign oki2_bank_we = wr_now && is_oki2_bank && !nLDS;
	assign oki_bank     = cpu_dout[1:0];

	assign prot_wr = wr_now && is_prot_w;
	assign prot_rd = mem_needed && !is_write && !acc_ready && (acc_ph == 2'd2) && is_prot_r;

	// ---- vblank IRQ: level 4, held until the CPU acknowledges ----
	// vblank is a LEVEL held for the full 38-line vertical blank (~2.4 ms).
	// The CPU acknowledges within microseconds, i.e. while vblank is still
	// high, so set-priority would discard the acknowledge and pin ipl at
	// level 4 forever -- the ISR would re-enter after every RTE. Match MAME's
	// irq4_line_hold: assert on the RISING edge, hold until acknowledged, and
	// let the acknowledge win.
	//
	// An interrupt-acknowledge cycle is FC=3'b111 during a real memory access.
	logic irq_pending, vblank_d;

	wire iack = mem_needed && (fc == 3'b111);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			irq_pending <= 1'b0;
			vblank_d    <= 1'b0;
		end else begin
			vblank_d <= vblank;
			if (iack)                      irq_pending <= 1'b0;
			else if (vblank && !vblank_d)  irq_pending <= 1'b1;
		end
	end

	// The kernel inverts IPL internally (IPL_nr <= NOT IPL), so level 4 is
	// requested by driving 3'b011, NOT 3'b100.
	assign ipl = irq_pending ? 3'b011 : 3'b111;

`ifdef DEBUG_ISSP
	// ISSP "C" (scripts/read_issp.tcl): where the 68020 is fetching and how far the boot
	// has got (protection handshake, interrupts, palette). Counters saturate, survive the
	// core's reset, and clear on source bit 0.
	logic        dbg_clr;
	logic [23:0] dbg_fetch;
	logic [15:0] dbg_iacks, dbg_prot_w, dbg_prot_r, dbg_pal_w, dbg_rom_rd;
	wire         dbg_consume = cpu_clkena && mem_needed;
	function automatic [15:0] sat_inc(input [15:0] v, input en);
		sat_inc = (en && v != 16'hFFFF) ? v + 16'd1 : v;
	endfunction
	always_ff @(posedge clk) begin
		if (dbg_consume && busstate == 2'b00) dbg_fetch <= a32[23:0];
		if (dbg_clr) begin
			dbg_iacks <= 0; dbg_prot_w <= 0; dbg_prot_r <= 0; dbg_pal_w <= 0; dbg_rom_rd <= 0;
		end else begin
			dbg_iacks  <= sat_inc(dbg_iacks,  dbg_consume && fc == 3'b111);
			dbg_prot_w <= sat_inc(dbg_prot_w, prot_wr);
			dbg_prot_r <= sat_inc(dbg_prot_r, prot_rd);
			dbg_pal_w  <= sat_inc(dbg_pal_w,  palette_wel || palette_weh);
			dbg_rom_rd <= sat_inc(dbg_rom_rd, rom_req);
		end
	end
	altsource_probe #(
		.sld_auto_instance_index("YES"),
		.instance_id("C"),
		.probe_width(107),
		.source_width(1),
		.source_initial_value("0"),
		.enable_metastability("NO"),
		.lpm_type("altsource_probe")
	) u_issp_cpu (
		.probe({irq_pending, pause, reset, dbg_rom_rd, dbg_pal_w, dbg_prot_r, dbg_prot_w,
		        dbg_iacks, dbg_fetch}),
		.source(dbg_clr),
		.source_clk(clk),
		.source_ena(1'b1)
	);
`endif

endmodule
