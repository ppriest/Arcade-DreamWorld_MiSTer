// SPDX-License-Identifier: GPL-3.0-or-later
// Bridges a byte- or word-wide req/valid read port onto a 64-bit-granule arbiter port, because
// sdram.sv's burst-4 controller only ever hands back a full 8-byte-aligned granule. Every narrow
// Port 2 consumer needs the same "fetch the containing granule, then pick the slice", so it is
// built once here.
//
// GRANULE CACHE: the last fetched granule is kept and any request falling inside it is served
// without a new transaction -- a 1-cycle hit instead of a full arbiter and controller round trip.
// The narrow consumers are dominated by sequential streams (68020 opcode fetch, four words a
// granule; spritelut, runs of consecutive tile codes), so this removes most of their Port 2 traffic,
// which otherwise contends with the sprite fetches. Every cached region is ROM, written only by the
// download, so the only invalidation needed is `inval`, tied to ioctl_download.
//
// Byte and word layout within a granule, from sdram.sv's read capture and sdram_chip_model.sv's
// write mask: word i (0-3, ascending byte address) occupies g_data[16*i +: 16], and within a word
// the even byte address is the low byte -- ordinary little-endian packing. So for a byte address
// `addr`, word_index = addr[2:1] and, for WORD_BYTES=1, byte_in_word = addr[0].
//
// req/valid contract: clients PULSE req (a held req would re-trigger this bridge) and hold `addr`
// stable until the valid pulse. Toward the arbiter the bridge holds g_req until g_valid, one request
// at a time, matching the arbiter's single-outstanding-transaction design.

module sdram_narrow_bridge #(
	parameter int WORD_BYTES = 2   // 1 = byte-wide client, 2 = word-wide client
									 // (spritelut and maincpu; this core uses 2 only)
) (
	input  logic clk,
	input  logic reset,

	// flush the granule cache (hold high while the backing store is being
	// written, i.e. ioctl_download)
	input  logic inval,

	// narrow client side
	input  logic                     req,
	input  logic [24:0]              addr,    // byte address of the desired unit
	output logic                     valid,
	output logic [8*WORD_BYTES-1:0] data,

	// wide granule side (one sdram_arbiter6 consumer port)
	output logic         g_req,
	output logic [24:0] g_addr,
	input  logic         g_valid,
	input  logic [63:0] g_data
);

	typedef enum logic [1:0] {B_IDLE, B_WAIT, B_HIT, B_DRAIN} bstate_t;
	bstate_t bstate;

	logic [1:0] word_sel;
	logic         byte_sel;

	// ---- granule cache ----
	logic [63:0] cache_data;
	logic [21:0] cache_tag;      // granule address, addr[24:3]
	logic         cache_valid;
	logic [21:0] tag_inflight;   // granule being fetched (latched at accept --
								  // addr is only guaranteed stable until valid)

	wire hit = cache_valid && (addr[24:3] == cache_tag);

	assign g_addr = {addr[24:3], 3'b000};   // 8-byte-align down to the granule base
	assign g_req  = (bstate == B_WAIT);

	// B_HIT serves from the cache; B_WAIT serves from the live granule the
	// cycle it arrives (and fills the cache the same cycle).
	logic [15:0] sel_word;
	assign sel_word = (bstate == B_HIT) ? cache_data[16*word_sel +: 16]
										  : g_data[16*word_sel +: 16];

	generate
		if (WORD_BYTES == 1) begin : g_byte
			assign data = byte_sel ? sel_word[15:8] : sel_word[7:0];
		end else begin : g_word
			assign data = sel_word;
		end
	endgenerate

	assign valid = ((bstate == B_WAIT) && g_valid) || (bstate == B_HIT);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			bstate       <= B_IDLE;
			cache_valid <= 1'b0;
		end else begin
			if (inval) cache_valid <= 1'b0;

			case (bstate)
				B_IDLE: begin
					if (req) begin
						word_sel <= addr[2:1];
						byte_sel <= addr[0];
						if (hit && !inval) begin
							bstate <= B_HIT;
						end else begin
							tag_inflight <= addr[24:3];
							bstate        <= B_WAIT;
						end
					end
				end
				B_WAIT: begin
					if (g_valid) begin
						if (!inval) begin
							cache_data  <= g_data;
							cache_tag   <= tag_inflight;
							cache_valid <= 1'b1;
						end
						bstate <= B_IDLE;
					end
				end
				B_HIT: begin
					// valid pulses this cycle (see assign above). Go through
					// B_DRAIN rather than straight to B_IDLE: a HELD-req
					// client (the OKI path holds req until valid, unlike the
					// pulse-req CPU fetches) clears its req only on the cycle
					// AFTER seeing valid, so B_IDLE would re-latch the still-high
					// req and serve a spurious second hit -- and a 1-cycle hit
					// would loop, where the old all-miss bridge's ~20-cycle
					// round trip made the extra serve harmless.
					bstate <= B_DRAIN;
				end
				B_DRAIN: begin
					if (!req) bstate <= B_IDLE;
				end
				default: bstate <= B_IDLE;
			endcase
		end
	end

endmodule
