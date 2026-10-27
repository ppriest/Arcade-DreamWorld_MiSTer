// SPDX-License-Identifier: GPL-3.0-or-later
// Routes Port 2's consumers onto one sdram_phy port: the two OKI sample caches, the spritelut, the
// main CPU's program fetch, and the HPS ROM download's write path. Client 3 has no user here.
//
// Hold-until-ack round robin among the read clients -- the served one rotates to the back, so
// sustained pressure from one cannot starve another -- with the download taking absolute priority:
// it runs only while a ROM loads, before gameplay, so it costs nothing at runtime.
//
// The arbiter knows only 64-bit granules (8-byte-aligned address in, burst-4 granule out), matching
// sdram_phy and sdram.sv. Narrower clients sit behind rtl/memory/sdram_narrow_bridge.sv, outside
// this module, so it stays transport with no per-consumer width or region knowledge.
//
// c0, c4: the two OKIs' sample streams, served ahead of the round robin (see below)
// c1:     spritelut (via sdram_narrow_bridge, WORD_BYTES=2)
// c2:     maincpu program fetch (via sdram_narrow_bridge, WORD_BYTES=2)
// c3:     no client in this core

module sdram_arbiter6 (
	input  logic clk,
	input  logic reset,

	// physical port (to sdram_phy)
	output logic         phy_req,
	output logic         phy_we,
	output logic         phy_we16,
	output logic [24:0] phy_addr,
	output logic [15:0] phy_wdata,
	input  logic         phy_busy,
	input  logic         phy_valid,
	input  logic [63:0] phy_rdata,

	// consumer 0: OKI 1 sample stream (sample_cache)
	input  logic         c0_req,
	input  logic [24:0] c0_addr,
	output logic         c0_valid,
	output logic [63:0] c0_data,

	// consumer 1: spritelut
	input  logic         c1_req,
	input  logic [24:0] c1_addr,
	output logic         c1_valid,
	output logic [63:0] c1_data,

	// consumer 2: maincpu program fetch
	input  logic         c2_req,
	input  logic [24:0] c2_addr,
	output logic         c2_valid,
	output logic [63:0] c2_data,

	// consumer 3: no client in this core
	input  logic         c3_req,
	input  logic [24:0] c3_addr,
	output logic         c3_valid,
	output logic [63:0] c3_data,

	// consumer 4: OKI 2 sample stream (sample_cache). Both OKI streams are
	// served ahead of the round robin -- see below.
	input  logic         c4_req,
	input  logic [24:0] c4_addr,
	output logic         c4_valid,
	output logic [63:0] c4_data,

	// HPS ROM-download write path -- absolute priority, hold dl_req until
	// dl_busy asserts (matches ddram_arbiter's own dl_req contract, NOT
	// hps_io's raw one-shot ioctl_wr pulse -- see rtl/memory/
	// sdram_download.sv for the translation layer)
	input  logic         dl_req,
	input  logic [24:0] dl_addr,
	input  logic [15:0] dl_data,
	input  logic         dl_we16,
	output logic         dl_busy
);

	logic [4:0] c_req;
	logic [24:0] c_addr [0:4];
	assign c_req    = {c4_req, c3_req, c2_req, c1_req, c0_req};
	assign c_addr[0] = c0_addr;
	assign c_addr[1] = c1_addr;
	assign c_addr[2] = c2_addr;
	assign c_addr[3] = c3_addr;
	assign c_addr[4] = c4_addr;

	typedef enum logic [1:0] {A_IDLE, A_ISSUE, A_WAIT_READ, A_WAIT_WRITE} astate_t;
	astate_t astate;

	logic [2:0] rr_ptr;
	logic [2:0] sel;
	logic         sel_is_dl;

	// The two OKI sample streams (c0, c4) are promoted above the round robin. They are the only
	// latency-critical clients on this port: jt6295 consumes a sample byte on a fixed cadence while
	// a voice plays, and a late byte is audible at once; sample_cache prefetches the next granule,
	// but a miss still shows. Spritelut and the CPU fetches have slack, and the streams' bandwidth
	// is negligible against the sprite and tilemap traffic, so promoting them costs the others
	// nothing.
	//
	// It matters because sdram.sv arbitrates its physical ports by FIXED priority, not fairly: port 0
	// (both tilemaps) preempts port 1 (sprite gfxrom), which preempts port 2 -- this arbiter. On a
	// busy screen the sample streams are already last in line physically and would then queue behind
	// the other clients here.
	//
	// adpcm_tog alternates between the two so neither can starve the other when both are streaming.
	logic [2:0] next_sel;
	logic         found;
	logic         adpcm_tog;
	always_comb begin
		found    = 1'b0;
		next_sel = rr_ptr;
		if (c_req[0] && c_req[4]) begin
			next_sel = adpcm_tog ? 3'd4 : 3'd0;
			found    = 1'b1;
		end else if (c_req[0]) begin
			next_sel = 3'd0;
			found    = 1'b1;
		end else if (c_req[4]) begin
			next_sel = 3'd4;
			found    = 1'b1;
		end else for (int i = 0; i < 5; i++) begin
			logic [3:0] sum;   // 4 bits: rr_ptr(<=4) + i(<=4). The earlier 3-bit sum wrapped 4+4 to
								// 0 before the >=5 check, so with rr_ptr==4 the scan set was
								// {4,0,1,2,0} and client 3 was never scanned -- a deadlock for a
								// solo c3 requester, starvation otherwise.
			sum = {1'b0, rr_ptr} + i[3:0];
			if (sum >= 4'd5) sum = sum - 4'd5;
			if (!found && c_req[sum[2:0]]) begin
				next_sel = sum[2:0];
				found    = 1'b1;
			end
		end
	end

	assign dl_busy = (astate != A_IDLE) && sel_is_dl;

	assign phy_addr  = sel_is_dl ? dl_addr : c_addr[sel];
	assign phy_wdata = dl_data;
	assign phy_we    = sel_is_dl;
	assign phy_we16  = dl_we16;
	assign phy_req   = (astate == A_ISSUE) && !phy_busy;

	assign c0_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd0) && phy_valid;
	assign c1_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd1) && phy_valid;
	assign c2_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd2) && phy_valid;
	assign c3_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd3) && phy_valid;
	assign c0_data  = phy_rdata;
	assign c1_data  = phy_rdata;
	assign c2_data  = phy_rdata;
	assign c3_data  = phy_rdata;
	assign c4_valid = (astate == A_WAIT_READ) && !sel_is_dl && (sel == 3'd4) && phy_valid;
	assign c4_data  = phy_rdata;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			astate <= A_IDLE;
			rr_ptr <= 3'd0;
			sel_is_dl <= 1'b0;
			adpcm_tog <= 1'b0;
		end else begin
			case (astate)
				A_IDLE: begin
					if (dl_req) begin
						sel_is_dl <= 1'b1;
						astate    <= A_ISSUE;
					end else if (found) begin
						sel       <= next_sel;
						sel_is_dl <= 1'b0;
						astate    <= A_ISSUE;
					end
				end

				A_ISSUE: begin
					// phy_req pulsed this cycle (combinational, gated by
					// !phy_busy). Once accepted, move to the matching wait
					// state; if phy_busy was unexpectedly still high (should
					// not happen given this arbiter fully serializes access
					// to sdram_phy), simply retry next cycle.
					if (!phy_busy) astate <= sel_is_dl ? A_WAIT_WRITE : A_WAIT_READ;
				end

				A_WAIT_READ: begin
					if (phy_valid) begin
						// alternate the ADPCM pair on each grant to one of them
						if (sel == 3'd0 || sel == 3'd4) adpcm_tog <= ~adpcm_tog;
						rr_ptr <= (sel == 3'd4) ? 3'd0 : sel + 3'd1;
						astate <= A_IDLE;
					end
				end

				A_WAIT_WRITE: begin
					if (!phy_busy) astate <= A_IDLE;
				end
			endcase
		end
	end

endmodule
