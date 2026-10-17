// Video-register decode for 0x804000-0x807FFF. dreamwld.cpp maps the
// row-scroll RAM at 0x804000-0x8043FF (word 0x000-0x0FF layer 0, 0x100-0x1FF
// layer 1) and the "vregs" share at 0x804400-0x805FFF; the scroll and layer
// control words sit at the same offsets as on the Psikyo boards. The
// tilemap engines read the row-scroll tables every line and six
// single-value registers (Y-scroll/X-scroll/control per layer) live.
//
// Backing storage is duplicated into two independent dpram copies (both
// always written identically from the CPU port) to get a second BRAM read
// port for the row-scroll tables. The six registers are latched into
// flip-flops on a matching CPU write instead of being read from the dpram.
module vreg_decode (
	input  logic         clk,
	input  logic         reset,

	// CPU-facing port -- same shape as maincpu.sv's other BRAM regions.
	input  logic [12:0] cpu_addr,
	input  logic         cpu_wel,
	input  logic         cpu_weh,
	input  logic [15:0] cpu_wdata,
	output logic [15:0] cpu_rdata,

	// Row-scroll table read ports, one per layer -- module-local index
	// 0-255 within that layer's table, matching tilemap_line_engine's
	// rowscroll_addr/rowscroll_data port shape.
	input  logic [7:0]  layer0_rowscroll_addr,
	output logic [15:0] layer0_rowscroll_data,
	input  logic [7:0]  layer1_rowscroll_addr,
	output logic [15:0] layer1_rowscroll_data,

	// Decoded per-layer control outputs, matching tilemap_line_engine's
	// mode/base_x_scroll/base_y_scroll/bank/rowscroll_enable/
	// rowscroll_pertile input port shape directly.
	output logic [1:0]  layer0_mode,
	output logic [15:0] layer0_base_x_scroll,
	output logic [15:0] layer0_base_y_scroll,
	output logic [1:0]  layer0_bank,
	output logic         layer0_rowscroll_enable,
	output logic         layer0_rowscroll_pertile,

	output logic [1:0]  layer1_mode,
	output logic [15:0] layer1_base_x_scroll,
	output logic [15:0] layer1_base_y_scroll,
	output logic [1:0]  layer1_bank,
	output logic         layer1_rowscroll_enable,
	output logic         layer1_rowscroll_pertile,

	// ---- debug dump port (rtl/dreamworld_core.sv drives this from the video
	// counters while the debug overlay is up). Borrows u_ram_l0's read port,
	// which normally only ever sees the 8-bit layer-0 rowscroll index, so it
	// cannot otherwise reach the control registers at word 0x209/0x20B. This
	// is what distinguishes "the CPU never wrote the layer control word" from
	// "it wrote it and vreg_decode failed to latch it" -- the two have
	// completely different fixes and look identical from outside.
	input  logic         dbg_dump_en,
	input  logic [12:0] dbg_dump_addr,
	output logic [15:0] dbg_dump_data
);

	// Fixed word offsets (byte offset >> 1): dreamwld.cpp reads m_vregs[0..5]
	// from the share at 0x804400.
	localparam logic [12:0] ADDR_L0_YSCROLL = 13'h201; // byte 0x402
	localparam logic [12:0] ADDR_L0_XSCROLL = 13'h203; // byte 0x406
	localparam logic [12:0] ADDR_L1_YSCROLL = 13'h205; // byte 0x40A
	localparam logic [12:0] ADDR_L1_XSCROLL = 13'h207; // byte 0x40E
	localparam logic [12:0] ADDR_L0_CTRL     = 13'h209; // byte 0x412
	localparam logic [12:0] ADDR_L1_CTRL     = 13'h20B; // byte 0x416

	logic [15:0] l0_ctrl, l1_ctrl;

	wire cpu_we = cpu_wel | cpu_weh;
	// Both byte lanes of these registers are always written together by
	// real code (word-sized scroll/control values) -- a lone byte write
	// still updates the whole register from cpu_wdata, matching how a real
	// 16-bit register would latch whichever lanes are enabled; scoped
	// this way (not per-lane) since nothing in this project's memory map
	// ever byte-writes these six fields individually.
	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			layer0_base_y_scroll <= 16'h0000;
			layer0_base_x_scroll <= 16'h0000;
			layer1_base_y_scroll <= 16'h0000;
			layer1_base_x_scroll <= 16'h0000;
			l0_ctrl               <= 16'h0000;
			l1_ctrl               <= 16'h0000;
		end else if (cpu_we) begin
			unique case (cpu_addr)
				ADDR_L0_YSCROLL: layer0_base_y_scroll <= cpu_wdata;
				ADDR_L0_XSCROLL: layer0_base_x_scroll <= cpu_wdata;
				ADDR_L1_YSCROLL: layer1_base_y_scroll <= cpu_wdata;
				ADDR_L1_XSCROLL: layer1_base_x_scroll <= cpu_wdata;
				ADDR_L0_CTRL:     l0_ctrl               <= cpu_wdata;
				ADDR_L1_CTRL:     l1_ctrl               <= cpu_wdata;
				default: ;
			endcase
		end
	end

	// Layer control word, dreamwld.cpp screen_update():
	//   bit 6      tile bank, +0x2000 tiles     (layer_ctrl >> 6) & 1
	//   bit 10     size: 0 = 64x64 tiles, 1 = 128x32 -- tilemap_addrgen's
	//              modes 0 and 1, which have exactly these geometries
	//   bits 9:8   row-scroll when either is set; bit 9 = one entry per tile
	//              row (tile_rowscroll = (layer_ctrl & 0x200) >> 7)
	// The board has no enable or transparent-pen bits: layer 0 is created
	// with no transparent pen (opaque), layer 1 with pen 0 (compositor.sv).
	assign layer0_mode              = {1'b0, l0_ctrl[10]};
	assign layer0_rowscroll_enable  = l0_ctrl[8] | l0_ctrl[9];
	assign layer0_rowscroll_pertile = l0_ctrl[9];
	assign layer0_bank              = {1'b0, l0_ctrl[6]};

	assign layer1_mode              = {1'b0, l1_ctrl[10]};
	assign layer1_rowscroll_enable  = l1_ctrl[8] | l1_ctrl[9];
	assign layer1_rowscroll_pertile = l1_ctrl[9];
	assign layer1_bank              = {1'b0, l1_ctrl[6]};

	logic [15:0] l0_ram_b_rdata;
	dpram #(.ADDR_WIDTH(13), .DATA_WIDTH(16)) u_ram_l0 (
		.clk(clk),
		.a_addr(cpu_addr), .a_wel(cpu_wel), .a_weh(cpu_weh), .a_wdata(cpu_wdata), .a_rdata(cpu_rdata),
		.b_addr(dbg_dump_en ? dbg_dump_addr : {5'b0, layer0_rowscroll_addr}),
		.b_rdata(l0_ram_b_rdata)
	);
	assign layer0_rowscroll_data = l0_ram_b_rdata;
	assign dbg_dump_data          = l0_ram_b_rdata;

	logic [15:0] cpu_rdata_l1; // unused -- l1's copy only needed for its own read port
	dpram #(.ADDR_WIDTH(13), .DATA_WIDTH(16)) u_ram_l1 (
		.clk(clk),
		.a_addr(cpu_addr), .a_wel(cpu_wel), .a_weh(cpu_weh), .a_wdata(cpu_wdata), .a_rdata(cpu_rdata_l1),
		.b_addr({4'b0, 1'b1, layer1_rowscroll_addr}), .b_rdata(layer1_rowscroll_data)
	);

endmodule
