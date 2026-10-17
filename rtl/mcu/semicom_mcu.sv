// The protection MCU: an 87C52 at 16 MHz (jt8052) running its own 8 KB ROM, and the board
// logic between it and the 68020 as dreamwld.cpp models it (lines 736-794):
//
//   MCU P1 write            port1 = data
//   MCU P2 write            bit 1 rising -> latch = port1; port2 = data
//   MCU P2 read             returns port2
//   68020 write to C00020   port2 &= ~0x04 ("data sent"); the data is not passed on
//   68020 read of C00030    port2 &= ~0x08 ("data received"); returns latch in bits 31:24
//
// The 68020 side's 50 us waits are in maincpu.sv. MAME leaves P0, P1 and P3 inputs and
// both interrupt pins unconnected; they read as idle here.
//
// The ROM is written by the download (dreamworld_sdram_top's tap), 4K x 16 with byte
// enables, even byte in the low lane, and read a byte at a time on cen as jt8052 expects
// (one cen of latency, like Eolith's BRAMs). Held in reset with the rest of the core.
module semicom_mcu (
	input  logic         clk,
	input  logic         reset,

	input  logic         rom_we,
	input  logic [11:0] rom_waddr,
	input  logic [15:0] rom_wdata,
	input  logic [1:0]  rom_wbe,

	input  logic         prot_wr,       // pulse: 68020 wrote C00020
	input  logic         prot_rd,       // pulse: 68020 read C00030
	output logic [7:0]  latch
);
	// 16 MHz oscillator enable from 54 MHz: Bresenham 8/27. jt8052 needs an idle clk
	// between enables (3.375 clk apart on average).
	logic [5:0] ce_acc;
	logic        cen;
	always_ff @(posedge clk) begin
		if (reset) begin
			ce_acc <= 6'd0;
			cen    <= 1'b0;
		end else if (ce_acc + 6'd8 >= 6'd27) begin
			ce_acc <= ce_acc + 6'd8 - 6'd27;
			cen    <= 1'b1;
		end else begin
			ce_acc <= ce_acc + 6'd8;
			cen    <= 1'b0;
		end
	end

	// Two 4096 x 8 arrays, even and odd byte, each one write and one read: the plain RAM
	// template. One 4096 x 16 array with per-lane writes in the same block as the enabled
	// read was built from 65,536 registers instead (build of 328b7df).
	logic [7:0]  rom_even [0:4095], rom_odd_b [0:4095];
	logic [7:0]  q_even, q_odd;
	logic        rom_odd;
	logic [15:0] rom_addr;
	always_ff @(posedge clk) begin
		if (rom_we && rom_wbe[0]) rom_even[rom_waddr] <= rom_wdata[7:0];
		if (cen) q_even <= rom_even[rom_addr[12:1]];
	end
	always_ff @(posedge clk) begin
		if (rom_we && rom_wbe[1]) rom_odd_b[rom_waddr] <= rom_wdata[15:8];
		if (cen) q_odd <= rom_odd_b[rom_addr[12:1]];
	end
	always_ff @(posedge clk) if (cen) rom_odd <= rom_addr[0];
	// An 87C52 has 8 KB on chip; above it the program would fetch from an external bus
	// the board does not wire (EA is high). The dumped program stays below 0x0800.
	wire [7:0] rom_data = rom_odd ? q_odd : q_even;

	logic [7:0] ram [0:255];
	logic [7:0] ram_q, ram_dout, ram_addr;
	logic        ram_we;
	always_ff @(posedge clk) if (cen) begin
		if (ram_we) ram[ram_addr] <= ram_dout;
		ram_q <= ram[ram_addr];
	end

	logic [7:0] p1_o, p2_o;
	logic        p2_we, p2_we_d;
	logic [7:0] port2;

	jt8052 u_mcu (
		.rst(reset), .clk(clk), .cen(cen), .int0n(1'b1), .int1n(1'b1),
		.p0_i(8'hff), .p1_i(8'hff), .p2_i(port2), .p3_i(8'hff),
		.p0_o(), .p1_o(p1_o), .p2_o(p2_o), .p3_o(),
		.rom_data(rom_data), .rom_addr(rom_addr),
		.ram_din(ram_q), .ram_dout(ram_dout), .ram_addr(ram_addr), .ram_we(ram_we),
		.x_din(8'hff), .x_dout(), .x_addr(), .x_wr(), .x_acc(),
		.p3_we(), .p3_latch(), .p1_we(), .p2_we(p2_we)
	);

	// p2_we is high for one cen period after the write, with p2_o already the new value:
	// act on its first clk. port1 is p1_o, the P1 latch as last written. A 68020 access in
	// the same clk as an MCU write clears its bit on top of the written value.
	wire       p2_write = p2_we && !p2_we_d;
	wire [7:0] p2_next  = p2_write ? p2_o : port2;
	always_ff @(posedge clk) begin
		if (reset) begin
			port2   <= 8'h00;       // dreamwld_state::machine_reset
			latch   <= 8'h00;
			p2_we_d <= 1'b0;
		end else begin
			p2_we_d <= p2_we;
			if (p2_write && !port2[1] && p2_o[1]) latch <= p1_o;
			port2 <= p2_next & ~{4'b0000, prot_rd, prot_wr, 2'b00};
		end
	end

`ifdef DEBUG_ISSP
	// ISSP "M" (scripts/read_issp.tcl): the MCU's fetch address, its ports and the handshake
	// as the board sees it. Counters saturate, survive the core's reset, and clear on
	// source bit 0.
	logic        dbg_clr;
	logic [15:0] dbg_p2_w, dbg_latches;
	always_ff @(posedge clk) begin
		if (dbg_clr) begin
			dbg_p2_w <= 0; dbg_latches <= 0;
		end else begin
			if (p2_write && dbg_p2_w != 16'hFFFF) dbg_p2_w <= dbg_p2_w + 16'd1;
			if (p2_write && !port2[1] && p2_o[1] && dbg_latches != 16'hFFFF) dbg_latches <= dbg_latches + 16'd1;
		end
	end
	altsource_probe #(
		.sld_auto_instance_index("YES"),
		.instance_id("M"),
		.probe_width(73),
		.source_width(1),
		.source_initial_value("0"),
		.enable_metastability("NO"),
		.lpm_type("altsource_probe")
	) u_issp_mcu (
		.probe({reset, dbg_latches, dbg_p2_w, p1_o, latch, port2, rom_addr}),
		.source(dbg_clr),
		.source_clk(clk),
		.source_ena(1'b1)
	);
`endif
endmodule
