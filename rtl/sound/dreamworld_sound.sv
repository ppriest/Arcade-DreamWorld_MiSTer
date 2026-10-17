// The board's sound: two OKI M6295 (jt6295), each with its sample-ROM bank register, mixed to
// mono (dreamwld.cpp 398-414, 431-446, 824-840).
//
// 1 MHz (XTAL 32 MHz / 32), one enable in 54; pin 7 low. The second chip exists on the
// dreamwld_map boards only (has_oki2: dreamwld, cutefght); elsewhere it is held in reset and
// silent, and maincpu does not decode it.
//
// ROM: each chip's address goes out as {bank, chip address}; the SDRAM side maps it
// (dreamworld_sdram_top). oki_rom_bridge turns the chip's level interface into held fetches.
//
// Mix: MAME scales a full-volume voice (12 bits) to full scale and sums both chips into the
// "mono" speaker at 1.0, clipping at the output; jt6295 sums its four voices into 14 bits, so
// the output is 16 x the two sums, clamped.
module dreamworld_sound (
	input  logic         clk,
	input  logic         reset,
	input  logic         has_oki2,

	// maincpu: 0xC00018 / 0xC00028 writes (one clk each) and reads, bank writes
	input  logic         oki1_wr,
	input  logic         oki2_wr,
	input  logic [7:0]  wdata,
	output logic [7:0]  oki1_dout,
	output logic [7:0]  oki2_dout,
	input  logic         oki1_bank_we,
	input  logic         oki2_bank_we,
	input  logic [1:0]  bank,

	// sample ROMs: {bank, chip address}, held req until valid
	output logic         oki1_rom_req,
	output logic [19:0] oki1_rom_addr,
	input  logic         oki1_rom_valid,
	input  logic [7:0]  oki1_rom_data,
	output logic         oki2_rom_req,
	output logic [19:0] oki2_rom_addr,
	input  logic         oki2_rom_valid,
	input  logic [7:0]  oki2_rom_data,

	output logic [15:0] audio
);
	logic [5:0] div;
	logic       cen;
	always_ff @(posedge clk) begin
		if (reset) begin
			div <= 6'd0;
			cen <= 1'b0;
		end else begin
			div <= (div == 6'd53) ? 6'd0 : div + 6'd1;
			cen <= (div == 6'd53);
		end
	end

	logic [1:0] oki1_bank, oki2_bank;
	always_ff @(posedge clk) begin
		if (reset) begin
			oki1_bank <= 2'd0;
			oki2_bank <= 2'd0;
		end else begin
			if (oki1_bank_we) oki1_bank <= bank;
			if (oki2_bank_we) oki2_bank <= bank;
		end
	end

	// okim6295::write ignores a start for a voice that is already playing ("fixes Got-cha and
	// Steel Force"); jt6295 restarts it. dreamwld re-sends a start to a playing voice with less
	// attenuation every 13.7 ms to fade a phrase in, which jt6295 would restart each time, louder.
	// So the second byte of a start reaches the chip with the busy voices masked off
	// (dout[3:0] is busy | start). The first/second byte state follows jt6295_ctrl's own.
	logic oki1_pend, oki2_pend;
	always_ff @(posedge clk) begin
		if (reset) begin
			oki1_pend <= 1'b0;
			oki2_pend <= 1'b0;
		end else begin
			if (oki1_wr) oki1_pend <= !oki1_pend && wdata[7];
			if (oki2_wr) oki2_pend <= !oki2_pend && wdata[7];
		end
	end
	wire [7:0] oki1_din = oki1_pend ? {wdata[7:4] & ~oki1_dout[3:0], wdata[3:0]} : wdata;
	wire [7:0] oki2_din = oki2_pend ? {wdata[7:4] & ~oki2_dout[3:0], wdata[3:0]} : wdata;

	logic [17:0] oki1_chip_addr, oki2_chip_addr;
	logic [7:0]  oki1_chip_data, oki2_chip_data;
	logic        oki1_chip_ok, oki2_chip_ok;
	logic signed [13:0] oki1_snd, oki2_snd;
	wire oki2_rst = reset | ~has_oki2;

	// jt6295 takes a write on the falling edge of wrn, sampled on clk
	jt6295 #(.INTERPOL(0)) u_oki1 (
		.rst(reset), .clk(clk), .cen(cen), .ss(1'b0),
		.wrn(~oki1_wr), .din(oki1_din), .dout(oki1_dout),
		.rom_addr(oki1_chip_addr), .rom_data(oki1_chip_data), .rom_ok(oki1_chip_ok),
		.sound(oki1_snd), .sample()
	);
	oki_rom_bridge u_oki1_bridge (
		.clk(clk), .reset(reset),
		.rom_addr(oki1_chip_addr), .rom_data(oki1_chip_data), .rom_ok(oki1_chip_ok), .bank(oki1_bank),
		.req(oki1_rom_req), .addr(oki1_rom_addr), .valid(oki1_rom_valid), .data(oki1_rom_data)
	);

	jt6295 #(.INTERPOL(0)) u_oki2 (
		.rst(oki2_rst), .clk(clk), .cen(cen), .ss(1'b0),
		.wrn(~oki2_wr), .din(oki2_din), .dout(oki2_dout),
		.rom_addr(oki2_chip_addr), .rom_data(oki2_chip_data), .rom_ok(oki2_chip_ok),
		.sound(oki2_snd), .sample()
	);
	oki_rom_bridge u_oki2_bridge (
		.clk(clk), .reset(oki2_rst),
		.rom_addr(oki2_chip_addr), .rom_data(oki2_chip_data), .rom_ok(oki2_chip_ok), .bank(oki2_bank),
		.req(oki2_rom_req), .addr(oki2_rom_addr), .valid(oki2_rom_valid), .data(oki2_rom_data)
	);

	logic signed [14:0] sum;
	logic signed [18:0] mix;
	always_ff @(posedge clk) begin
		sum   <= oki1_snd + (has_oki2 ? oki2_snd : 14'sd0);
		mix   <= {sum, 4'b0000};
		audio <= (mix >  19'sd32767) ? 16'sh7FFF :
		         (mix < -19'sd32768) ? 16'sh8000 : mix[15:0];
	end
endmodule
