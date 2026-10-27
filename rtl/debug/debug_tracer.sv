// SPDX-License-Identifier: GPL-3.0-or-later
// On-hardware trace buffer for bring-up, read out through the video output and controlled live
// from the OSD.
//
// Two invariants, both learned the hard way (docs/LESSONS_LEARNED.md, "Debug instrumentation: how
// to not fool yourself"):
//
//   1. NO RESET PORT. MiSTer holds core RESET for the whole ROM download, which zeroed the very
//      counters being investigated. Registers power up to zero at configuration and are re-armed
//      deliberately; do not add a reset.
//   2. Capture takes an explicit one-cycle `cap_stb`, so the sampling edge is a deliberate
//      decision. Prove it in simulation against a known-good run before trusting its output.
//
// Capture: pulse `cap_stb` with `cap_data` valid. Recording stops when the buffer is full and holds
// its contents, so a screenshot can be taken at any time. `rd_index` is normally the video line
// counter, giving DEPTH consecutive events per screenshot; `rd_data` is a real BRAM read port and
// lags one cycle, which does not matter at line rate.
//
// Window: `ctl_window` skips ctl_window*8191 events before recording, so the window can be walked
// across a long boot sequence from the OSD with no rebuild.
//
// Re-arm: any change on `ctl_rearm` (an OSD bit) restarts capture with the current window, without
// resetting the core. Recording starts at configuration, so the power-on boot is caught by default.

module debug_tracer #(
	parameter int DEPTH = 256,   // entries
	parameter int WIDTH = 24,    // bits per entry (24 = one RGB pixel)

	// Compile-time DEFAULT for ring mode; `ctl_ring` selects it live.
	// 0 = record the FIRST DEPTH events after arming, then hold.
	// 1 = keep overwriting, so the buffer always holds the MOST RECENT DEPTH
	//     events, and freeze once the event stream has been quiet for
	//     2**IDLE_BITS clk.
	parameter bit MODE_RING = 1'b0,
	parameter int IDLE_BITS = 22   // ring mode: freeze after 2**IDLE_BITS idle clks
) (
	input  logic              clk,

	// ---- capture side ----
	input  logic              cap_stb,    // ONE cycle per event
	input  logic [WIDTH-1:0]  cap_data,

	// ---- live control (OSD status bits; deliberately NOT reset-coupled) ----
	input  logic              ctl_rearm,  // any change restarts capture
	input  logic [3:0]        ctl_window, // skip ctl_window*8191 events first
	input  logic              ctl_ring,   // 1 = ring (latest N), 0 = first N
	input  logic              ctl_trig_en,// 1 = freeze on first cap_trig

	// TRIGGER. Ring mode alone shows the most recent events, which a stuck CPU's tight loop simply
	// overwrites. Freezing on the FIRST cap_trig instead leaves the DEPTH events leading up to it,
	// which is what identifies a cause.
	input  logic              cap_trig,

	// ---- readout ----
	input  logic [8:0]        rd_index,
	output logic [WIDTH-1:0]  rd_data,

	// Ring mode: high once the event stream has gone quiet and the buffer has
	// stopped moving. Echo this somewhere visible -- a static screenshot of a
	// churning ring is meaningless, and this is how you tell the two apart.
	output logic              frozen
);

	localparam int AW = $clog2(DEPTH);

	(* ramstyle = "no_rw_check" *) logic [WIDTH-1:0] mem [0:DEPTH-1];

	// NOTE the initialisers and the deliberate absence of any reset -- see
	// the header. Quartus powers these to 0 at configuration.
	logic [AW:0]  wptr      = '0;   // extra MSB is the "full" flag
	logic [19:0]  skip_cnt  = '0;
	logic         rearm_d   = 1'b0;

	wire full        = wptr[AW];

	// Skip step is ctl_window * 8191 -- deliberately ODD, and deliberately not
	// a multiple of DEPTH: a power-of-two step lands on a period boundary of
	// any event stream whose period divides it, making every window setting
	// produce a byte-identical capture -- indistinguishable from a genuine
	// periodic fault. An odd step cannot alias with a power-of-two period.
	// 8191 also makes the range useful: window 15 skips ~123k events,
	// enough to walk past the boot ROM checksum (~96k long reads).
	wire [19:0] skip_target = ({16'd0, ctl_window} << 13) - {16'd0, ctl_window};

	// Ring mode: count clk cycles since the last event; saturate at the top.
	// IDLE_BITS=22 is ~78 ms at 54 MHz -- comfortably longer than a frame, so
	// a legitimate lull across a vblank boundary cannot trip it, while a CPU
	// that has genuinely stopped fetching does.
	logic [IDLE_BITS-1:0] idle_cnt = '0;
	wire idle_hit = &idle_cnt;

	logic trig_seen = 1'b0;

	// In ring mode the buffer stops either because the stream went quiet or
	// because the trigger fired. `frozen` is combinational from the REGISTERED
	// trig_seen, so on the trigger cycle frozen is still 0 and that event is
	// captured as the newest entry, with its lead-up behind it.
	assign frozen = ctl_ring ? (idle_hit | trig_seen) : full;

	always_ff @(posedge clk) begin
		rearm_d <= ctl_rearm;

		if (ctl_rearm != rearm_d) begin
			// deliberate re-arm from the OSD -- restart with the current window
			wptr      <= '0;
			skip_cnt  <= '0;
			idle_cnt  <= '0;
			trig_seen <= 1'b0;
		end else if (cap_stb) begin
			idle_cnt <= '0;
			if (ctl_trig_en && cap_trig) trig_seen <= 1'b1;
			if (!frozen) begin
				if (skip_cnt < skip_target) begin
					skip_cnt <= skip_cnt + 20'd1;
				end else begin
					// In ring mode wptr simply wraps: mem is indexed by
					// wptr[AW-1:0], so the oldest entry is overwritten and the
					// buffer always holds the most recent DEPTH events.
					mem[wptr[AW-1:0]] <= cap_data;
					wptr              <= wptr + 1'b1;
				end
			end
		end else if (ctl_ring && !idle_hit) begin
			idle_cnt <= idle_cnt + 1'b1;
		end
	end

	// MODE_RING is retained only as documentation of the intended default;
	// ctl_ring is the live selector. Reference it so lint does not flag it.
	// verilator lint_off UNUSED
	wire _unused_mode_ring = MODE_RING;
	// verilator lint_on UNUSED

	// Registered read -- infers a proper BRAM port rather than a huge mux.
	always_ff @(posedge clk) begin
		rd_data <= mem[rd_index[AW-1:0]];
	end

endmodule
