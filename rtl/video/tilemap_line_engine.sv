// SPDX-License-Identifier: GPL-3.0-or-later
// Tilemap scanline sequencer -- one instance per layer. Drives the combinational address/decode
// chain (tilemap_coord -> tilemap_addrgen -> tile_cell_decode -> tile_row_decode) and prefetches
// up to PREFETCH_DEPTH tiles ahead of display through a ring buffer, so a stalled SDRAM fetch does
// not leave a gap on screen.
//
// One tile is due every 16 pixels, i.e. every 128 clk at ce_pix = clk/8. The row-scroll table is
// indexed by the raw scanline, not the Y-scrolled one.

module tilemap_line_engine #(
	parameter int LAYER = 0,   // 0 or 1 -- passed through to tile_cell_decode
	// Ring buffer depth. 32 >= the 21 tiles fetched per line, so the ring
	// cannot wrap mid-line; at 8 it wrapped 2.6 times per line, and an
	// off-by-one at a wrap would shift every tile after it.
	parameter int PREFETCH_DEPTH = 32
) (
	input  logic        clk,
	input  logic         reset,

	// Timing: vcnt is the active scanline.
	input  logic [7:0]  vcnt,        // 0-223, current active scanline
	// One pixel is consumed per ce_pix, not per clk. clk is 54 MHz and the
	// pixel clock is 54/8 = 6.75 MHz; without this the display side drains
	// the line's 21 prefetched tiles (336 pixels, one per clk) in 336/8 = 42
	// pixel clocks and reports fetch_overrun for the rest of the line --
	// correct content in columns 0..41 of every scanline, backdrop across
	// the remaining 266.
	input  logic         ce_pix,      // 1-in-8 pixel-clock enable
	input  logic         h_active,    // 1 while the active 320-pixel window is being displayed
	input  logic         line_start,  // 1-cycle pulse during blanking, well before h_active next asserts

	// Per-layer control/scroll registers (sampled once per line at line_start)
	input  logic [1:0]  mode,
	input  logic [15:0] base_x_scroll,
	input  logic [15:0] base_y_scroll,
	input  logic [1:0]  bank,
	input  logic         rowscroll_enable,
	input  logic         rowscroll_pertile,

	// Flip Screen DIP: the screen is the unflipped screen rotated 180
	// degrees. Screen line y shows source line 223-y (so the rowscroll table
	// is read bottom-up too), and screen column x shows source column 319-x,
	// so the line is fetched from its right-hand end and walked backwards.
	// Sampled at line_start.
	input  logic         flip,

	// Row-scroll table read port (module-local index 0-255 within this
	// layer's table; caller adds the layer's base offset when addressing
	// the shared vregs BRAM). 1-cycle synchronous read latency.
	output logic [7:0]  rowscroll_addr,
	input  logic [15:0] rowscroll_data,

	// VRAM read port. 1-cycle synchronous read latency.
	output logic [11:0] vram_addr,
	input  logic [15:0] vram_data,

	// gfx ROM read port: request/valid handshake, latency not assumed.
	//
	// gfxrom_req deasserts COMBINATIONALLY on gfxrom_valid (see the assign
	// below). A registered clear leaves req high for one cycle after valid,
	// and sdram_phy samples req on that same cycle, launching a duplicate
	// transaction for the address it had just served; every later response
	// then belonged to the previous request, so tile N-1's shape was drawn at
	// position N in N's colour -- the one-tile offset and the wrong-palette
	// tiles. Short-latency testbenches dropped the duplicate response between
	// FSM states and never showed it.
	output logic         gfxrom_req,
	output logic [21:0] gfxrom_addr,   // tile_number*128 + fine_y*8
	input  logic         gfxrom_valid,
	input  logic [63:0] gfxrom_data,   // 8 bytes, MSB-first (matches tile_row_decode's row_bytes[0])

	output logic         pixel_valid,
	output logic [3:0]  pixel_index,
	output logic [6:0]  pixel_color,
	output logic         fetch_overrun, // sticky: fetch pipeline didn't keep up with display
	// One-cycle pulse on the same event. The sticky flag saturates within
	// seconds of boot, so it cannot distinguish 'a few at startup' from
	// 'thousands per second under load' -- which is exactly the question
	// when chasing a load-dependent artefact. Counted in dreamworld_core.
	output logic         overrun_ev
`ifdef DEBUG_ISSP
	,
	// Fetch-pipeline stages, latched by the caller (dreamworld_core.sv's issp_probe)
	// when a bad tile is displayed. No cost to the shipping build.
	output logic [11:0] dbg_fetch_vram_addr,
	output logic [15:0] dbg_vram_data,
	output logic [14:0] dbg_cell_tile_number,
	output logic [6:0]  dbg_cell_color,
	output logic [1:0]  dbg_mode_latched,
	output logic [1:0]  dbg_bank_latched,
	output logic [11:0] dbg_pixel_src_addr,
	output logic [15:0] dbg_pixel_src_word
`endif
);

	// Declared here (top of the body), not next to buf_pixels/buf_ready
	// below where it's conceptually explained -- PTR_W is used by
	// fetch_target's declaration, which comes first in file order, and this
	// toolchain (vlog -sv) does not resolve forward references to
	// body-local declarations across statements (same class of issue as
	// sdram.sv's mode/reset reordering, see rtl/memory/sdram/PROVENANCE.md).
	localparam int PTR_W = $clog2(PREFETCH_DEPTH);

	// ---- combinational address/decode chain, fed by registered fetch state ----

	logic [15:0] fetch_eff_x, eff_y_latched;
	logic [1:0]  mode_latched, bank_latched;

	logic [7:0] tile_col;
	logic [6:0] tile_row;
	logic [3:0] fine_x_unused, fine_y;

	tilemap_coord u_coord (
		.mode(mode_latched),
		.eff_x(fetch_eff_x),
		.eff_y(eff_y_latched),
		.tile_col(tile_col),
		.tile_row(tile_row),
		.fine_x(fine_x_unused),
		.fine_y(fine_y)
	);

	logic [11:0] fetch_vram_addr;
	tilemap_addrgen u_addrgen (
		.mode(mode_latched),
		.col(tile_col),
		.row(tile_row),
		.vram_index(fetch_vram_addr)
	);

	assign vram_addr = fetch_vram_addr;

	logic [14:0] cell_tile_number;
	logic [6:0]  cell_color;
	tile_cell_decode #(.LAYER(LAYER)) u_celldec (
		.vram_cell(vram_data),
		.bank(bank_latched),
		.tile_number(cell_tile_number),
		.color(cell_color)
	);

	logic [7:0] row_bytes [0:7];
	always_comb begin
		row_bytes[0] = gfxrom_data[63:56];
		row_bytes[1] = gfxrom_data[55:48];
		row_bytes[2] = gfxrom_data[47:40];
		row_bytes[3] = gfxrom_data[39:32];
		row_bytes[4] = gfxrom_data[31:24];
		row_bytes[5] = gfxrom_data[23:16];
		row_bytes[6] = gfxrom_data[15:8];
		row_bytes[7] = gfxrom_data[7:0];
	end

	logic [3:0] decoded_pixel [0:15];
	tile_row_decode u_rowdec (
		.row_bytes(row_bytes),
		.flip_x(1'b0),   // tilemap cells carry no flip bit (sprites do; tiles don't)
		.pixel(decoded_pixel)
	);

	// ---- fetch FSM ----

	typedef enum logic [2:0] {
		S_IDLE, S_ROWSCROLL_WAIT, S_ROWSCROLL_WAIT2, S_WAIT_FREE, S_COORD, S_CELLDEC, S_GFXROM_WAIT, S_STORE_DONE
	} state_t;
	state_t state;

	logic [3:0]  fine_x_initial;
	logic        first_tile;
	logic [4:0]  tiles_to_fetch;
	logic [PTR_W-1:0] fetch_target;   // which buffer index the fetch engine is filling

	// sampled at line_start, held stable through S_ROWSCROLL_WAIT
	logic [15:0] base_x_first_latched;
	logic        rowscroll_en_latched;
	logic        flip_latched;

	// One-PIXEL alignment bias, measured on hardware against MAME: screen_x
	// shows tilemap pixel (scroll + screen_x + 1), moving the image one pixel
	// LEFT of the unbiased sum. Applied to the shared per-line sum so
	// row-scroll lines get the same bias; both layers inherit it. The sign is
	// hardware-verified -- do not flip it from re-derivation alone
	// (docs/LESSONS_LEARNED.md, "Don't guess a sign twice").
	//
	// Flip Screen: screen line y shows source line 223-y (so the row-scroll
	// table is read bottom-up too) and screen column c shows source column
	// 319-c, with the fetch walking left. The first pixel reaches the screen
	// at column 1, not 0, because it is registered on the ce_pix edge that
	// advances hcnt. Unflipped that column is scroll + 1, the bias above.
	// Flipped it must be source column 318, so the line starts at tilemap
	// pixel scroll + 318. (scroll + 320 -- 319 plus the unflipped bias --
	// put both tilemaps two pixels right of the rotated picture;
	// sim/tilemap_flip_tb checks it by screen column.)
	wire [7:0]  src_line     = flip ? (8'd223 - vcnt) : vcnt;
	wire [7:0]  rs_line      = src_line + 8'd32;
	wire [15:0] line_x_first = base_x_first_latched + (rowscroll_en_latched ? rowscroll_data : 16'd0);

	logic [14:0] tile_number_reg;
	logic [6:0]  color_reg;
`ifdef DEBUG_ISSP
	// Frozen at the same cycle as color_reg (S_CELLDEC), not read live at
	// S_GFXROM_WAIT: the CPU can legitimately write this VRAM cell while the
	// GFX-ROM fetch is in flight, and a later read would make buf_src_word
	// disagree with buf_color for reasons unrelated to the pipeline.
	logic [15:0] vram_data_reg;
`endif

	// Prefetch ring buffer, PREFETCH_DEPTH tiles deep. It was a 2-entry
	// ping-pong until measurement against the real SDRAM transport showed
	// that is not enough margin: sdram.sv's three ports share one internal
	// transaction pipeline, so when both tilemap layers request in the same
	// window one waits out the other's full round trip (measured: 15 cycles
	// nominal, 22 or 35 under contention). Depth 32 absorbs a line's worth of
	// stalls; a faster fetch-domain clock would be the real fix, but it is a
	// larger change.
	logic [3:0] buf_pixels [0:PREFETCH_DEPTH-1][0:15];
	logic [6:0] buf_color  [0:PREFETCH_DEPTH-1];
`ifdef DEBUG_ISSP
	// Tags each slot with the VRAM address it was fetched from, so the display
	// side can name the address the pixel on screen actually came from. The
	// fetch side's cell_color is dozens of tiles ahead and describes a
	// different tile, so it cannot serve as that reference.
	logic [11:0] buf_src_addr [0:PREFETCH_DEPTH-1];
	// The raw VRAM word fetched into this slot, so the display side can check
	// buf_color[slot] against the colour field of its own source word. Any
	// disagreement is buffer-level corruption, proved without an external
	// reference or timing assumption.
	logic [15:0] buf_src_word [0:PREFETCH_DEPTH-1];
`endif
	logic [3:0] buf_start  [0:PREFETCH_DEPTH-1];
	logic [4:0] buf_count  [0:PREFETCH_DEPTH-1];

	// Buffer-ready handshake, race-free by construction: each toggle bit has
	// exactly one writer (fetch_tog here, disp_tog in the display block), and
	// "ready to display" / "free for fetch" are derived combinationally by
	// comparing them, never written directly by either side.
	logic fetch_tog [0:PREFETCH_DEPTH-1];
	logic disp_tog  [0:PREFETCH_DEPTH-1];
	logic buf_ready [0:PREFETCH_DEPTH-1];
	generate
		genvar gi;
		for (gi = 0; gi < PREFETCH_DEPTH; gi++) begin : g_buf_ready
			assign buf_ready[gi] = fetch_tog[gi] ^ disp_tog[gi];
		end
	endgenerate

	// Registered request flag, gated combinationally so the EXTERNAL req
	// line drops the same cycle gfxrom_valid pulses -- the registered
	// clear in S_GFXROM_WAIT is one cycle too late for sdram_phy.sv, which
	// is back in S_IDLE sampling req that very cycle and would start a
	// duplicate transaction (see the gfxrom_req port comment above).
	logic gfxrom_req_r;
	assign gfxrom_req = gfxrom_req_r & ~gfxrom_valid;

	always_ff @(posedge clk) begin
		if (reset) begin
			state          <= S_IDLE;
			for (int i = 0; i < PREFETCH_DEPTH; i++) fetch_tog[i] <= 1'b0;
			gfxrom_req_r   <= 1'b0;
		end else if (line_start) begin
			// A new line always takes priority over whatever the fetch FSM is still doing for the
			// previous one. The 21-tile budget is throttled by the display's consumption rate, so
			// the last tile routinely finishes at or after h_active ends and the next line_start
			// arrives mid-fetch; checking only in S_IDLE silently dropped that pulse and desynced
			// the pipeline for the rest of the frame. Restarting unconditionally abandons any
			// in-flight request -- a late gfxrom_valid for it is harmless, as no state reacts to
			// it before the next real request.
			mode_latched          <= mode;
			flip_latched          <= flip;
			bank_latched          <= bank;
			// pixel k of the line is screen x k (video_timing); flipped, it is screen x 307 - k
			base_x_first_latched  <= base_x_scroll + (flip ? 16'd307 : 16'd0);
			rowscroll_en_latched  <= rowscroll_enable;
			// dreamwld.cpp: linebase[((y + 32) & 0xff) >> tile_rowscroll]
			rowscroll_addr        <= rowscroll_pertile ? {4'd0, rs_line[7:4]} : rs_line;
			for (int i = 0; i < PREFETCH_DEPTH; i++) fetch_tog[i] <= 1'b0;
			fetch_target          <= '0;
			first_tile            <= 1'b1;
			tiles_to_fetch        <= 5'd21;  // fixed worst-case count, see doc
			gfxrom_req_r          <= 1'b0;   // abort any in-flight request cleanly
			// stash what S_ROWSCROLL_WAIT needs that isn't re-derivable there
			eff_y_latched         <= base_y_scroll + {8'd0, src_line};
			state                 <= S_ROWSCROLL_WAIT;
		end else begin
			unique case (state)

				S_IDLE: begin
					// line_start is handled above (any state, not just
					// here) -- nothing to do while idle and no new line
					// has started yet.
				end

				S_ROWSCROLL_WAIT: begin
					// Burn one cycle: rowscroll_addr was REGISTERED on the
					// line_start edge, so the row-scroll RAM only samples it
					// at the end of THIS cycle and its data is not valid
					// until the next one (the port's 1-cycle synchronous
					// read; rtl/memory/dpram.sv port B). Consuming
					// line_x_first here read the PREVIOUS line's entry, so
					// every line was scrolled by its neighbour's value --
					// visible only where the table changes sharply line to
					// line.
					state <= S_ROWSCROLL_WAIT2;
				end

				S_ROWSCROLL_WAIT2: begin
					// line_x_first is a comb wire (above) so no procedural
					// temp is needed here.
					fine_x_initial <= line_x_first[3:0];
					fetch_eff_x    <= {line_x_first[15:4], 4'd0};   // tile-align
					state          <= S_WAIT_FREE;
				end

				// Throttle: only start the next fetch once the target
				// buffer has actually been consumed by the display side.
				// Without it the FSM races through all 21 tiles
				// back-to-back during blanking, repeatedly overwriting
				// both buffers with tiles far past the correct starting
				// one before display ever begins.
				S_WAIT_FREE: begin
					if (!buf_ready[fetch_target])
						state <= S_COORD;
				end

				S_COORD: begin
					// vram_addr is combinational (tilemap_coord+addrgen fed by
					// fetch_eff_x/eff_y_latched/mode_latched, all stable
					// registers at this point) -- nothing to do here but wait
					// one cycle for the synchronous VRAM read.
					state <= S_CELLDEC;
				end

				S_CELLDEC: begin
					// vram_data now reflects fetch_vram_addr; tile_cell_decode
					// output is valid combinationally this cycle.
					tile_number_reg <= cell_tile_number;
					color_reg       <= cell_color;
`ifdef DEBUG_ISSP
					vram_data_reg    <= vram_data;
`endif
					gfxrom_addr     <= {cell_tile_number, fine_y, 3'b000};
					gfxrom_req_r    <= 1'b1;
					state           <= S_GFXROM_WAIT;
				end

				S_GFXROM_WAIT: begin
					if (gfxrom_valid) begin
						gfxrom_req_r <= 1'b0;
						for (int i = 0; i < 16; i++)
							buf_pixels[fetch_target][i] <= decoded_pixel[i];
						buf_color[fetch_target] <= color_reg;
`ifdef DEBUG_ISSP
						buf_src_addr[fetch_target] <= fetch_vram_addr;
						buf_src_word[fetch_target] <= vram_data_reg;
`endif
						// The first tile starts at the fine offset either way.
						// Unflipped it shows fine..15 moving right; flipped it
						// shows fine..0 moving left, and every later tile
						// starts from its far end (15) instead of 0.
						if (first_tile) begin
							buf_start[fetch_target] <= fine_x_initial;
							buf_count[fetch_target] <= flip_latched ? {1'b0, fine_x_initial} + 5'd1
							                                        : 5'd16 - {1'b0, fine_x_initial};
						end else begin
							buf_start[fetch_target] <= flip_latched ? 4'd15 : 4'd0;
							buf_count[fetch_target] <= 5'd16;
						end
						state <= S_STORE_DONE;
					end
				end

				S_STORE_DONE: begin
					fetch_tog[fetch_target] <= ~fetch_tog[fetch_target];
					first_tile              <= 1'b0;
					fetch_eff_x             <= flip_latched ? fetch_eff_x - 16'd16 : fetch_eff_x + 16'd16;
					tiles_to_fetch          <= tiles_to_fetch - 5'd1;
					fetch_target            <= (fetch_target == PREFETCH_DEPTH-1) ? '0 : fetch_target + 1'b1;
					if (tiles_to_fetch > 5'd1)
						state <= S_WAIT_FREE;
					else
						state <= S_IDLE;
				end

			endcase
		end
	end

	// ---- display side: independent of the fetch FSM's state, synchronized
	// only via buf_ready/display_sel/consumed.
	//
	// pixel_valid/pixel_index/pixel_color are registered together here from the
	// current (pre-update) display_sel/consumed/buf_ready, so they carry the
	// same one-cycle latency from h_active and stay mutually consistent.
	//
	// fetch_overrun is driven only from here: one procedural driver per signal.

	logic [PTR_W-1:0] display_sel;
	logic [3:0]        consumed;

	always_ff @(posedge clk) begin
		if (reset) begin
			display_sel   <= '0;
			consumed      <= 4'd0;
			pixel_valid   <= 1'b0;
			pixel_index   <= 4'd0;
			pixel_color   <= 7'd0;
`ifdef DEBUG_ISSP
			dbg_pixel_src_addr <= 12'd0;
			dbg_pixel_src_word <= 16'd0;
`endif
			fetch_overrun <= 1'b0;
			for (int i = 0; i < PREFETCH_DEPTH; i++) disp_tog[i] <= 1'b0;
		end else if (line_start) begin
			display_sel <= '0;
			consumed    <= 4'd0;
			pixel_valid <= 1'b0;
			for (int i = 0; i < PREFETCH_DEPTH; i++) disp_tog[i] <= 1'b0;
		end else if (h_active) begin
			// Advance only on a pixel-clock tick; between ticks hold the
			// current pixel so the compositor sees a stable value for the
			// whole pixel period.
			if (ce_pix) begin
				if (buf_ready[display_sel]) begin
					pixel_valid <= 1'b1;
					pixel_index <= buf_pixels[display_sel][flip_latched ? buf_start[display_sel] - consumed
					                                                    : buf_start[display_sel] + consumed];
					pixel_color <= buf_color[display_sel];
`ifdef DEBUG_ISSP
					dbg_pixel_src_addr <= buf_src_addr[display_sel];
					dbg_pixel_src_word <= buf_src_word[display_sel];
`endif

					if ({1'b0, consumed} + 5'd1 >= buf_count[display_sel]) begin
						disp_tog[display_sel] <= ~disp_tog[display_sel];  // free this buffer
						display_sel            <= (display_sel == PREFETCH_DEPTH-1) ? '0 : display_sel + 1'b1;
						consumed                <= 4'd0;
					end else begin
						consumed <= consumed + 4'd1;
					end
				end else begin
					pixel_valid   <= 1'b0;
					fetch_overrun <= 1'b1;   // wanted to display but buffer wasn't ready
				end
			end
		end else if (ce_pix) begin
			// the line's last pixel, taken at hcnt 307, is on the output for the whole of the
			// next pixel period (video_timing)
			pixel_valid <= 1'b0;
		end
	end

`ifdef DEBUG_ISSP
	// Pass-through of the internal fetch-pipeline signals for the debug tag (see
	// the port declarations above). Not latched: the caller captures a snapshot.
	assign dbg_fetch_vram_addr  = fetch_vram_addr;
	assign dbg_vram_data         = vram_data;
	assign dbg_cell_tile_number = cell_tile_number;
	assign dbg_cell_color        = cell_color;
	assign dbg_mode_latched      = mode_latched;
	assign dbg_bank_latched      = bank_latched;
`endif


	// One-cycle pulse marking the same event fetch_overrun latches. Kept in its
	// own block because the FSM above is a reset/line_start/h_active if-chain
	// with no common fall-through, so there is nowhere to put a per-cycle
	// default without restructuring it.
	always_ff @(posedge clk or posedge reset) begin
		if (reset) overrun_ev <= 1'b0;
		else       overrun_ev <= h_active && ce_pix && !buf_ready[display_sel];
	end

endmodule
