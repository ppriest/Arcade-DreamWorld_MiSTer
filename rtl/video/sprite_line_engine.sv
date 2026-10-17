// Per-scanline sprite renderer: draws the sprites crossing one line into a 308-pixel line
// buffer (sprite_line_buffer), the line before it is shown.
//
// Per line: scan the frame's candidate table (sprite_line_list, built once in vblank) one entry
// a cycle; for each sprite crossing the line, find the sub-tile row it shows there, then for each
// sub-tile column fetch its spritelut word and its 8-byte gfx row. The fetched rows queue for a
// draw stage that writes 16 pixels each, so fetching overlaps drawing (see the queue below). Line
// budget: 3552 clk less the buffer clear.
//
// line_tick (every line) hard-resyncs: a line still being rendered is cut short -- at worst its
// last, topmost sprites -- any in-flight SDRAM request is drained per the req/valid contract,
// and ovr_ev pulses for the debug overlay. Without it, an overrun ate the next line_start and
// corrupted every line below.
//
// The decode modules (sprite_record_decode, sprite_pos_transform, sprite_zoom_lut,
// sprite_subtile_step, sprite_zoom_src_index) are fed zoom 0: the board has none. The coarse
// y-test can produce a conservative false hit; S_FIND_ROW re-does the exact per-row math.

module sprite_line_engine (
	input  logic clk,
	input  logic reset,

	input  logic         line_tick,     // raw per-line pulse (every line): hard resync point
	input  logic         line_start,    // gated pulse: begin rendering `render_line`
	input  logic [7:0]  render_line,   // 0-223, sampled at line_start
	output logic         busy,
	output logic         ovr_ev,         // pulse: a line was cut short by the resync

	// compact table ports (sprite_line_list, 1-cycle sync reads)
	output logic [9:0]  scan_addr,
	input  logic [17:0] scan_ytest,    // { y_top[9:0] signed, span_y[7:0] }
	output logic [9:0]  rec_addr,
	input  logic [63:0] rec_data,       // { word_y, word_x, word_attr, word_code_lo }
	input  logic [10:0] count,

	// spritelut ROM
	output logic         lut_req,
	output logic [16:0] lut_addr,
	input  logic         lut_valid,
	input  logic [15:0] lut_data,

	// sprite gfx ROM
	output logic         gfxrom_req,
	output logic [22:0] gfxrom_addr,
	input  logic         gfxrom_valid,
	input  logic [63:0] gfxrom_data,

	// line buffer write port
	output logic         fb_we,
	output logic [8:0]  fb_x,
	output logic [3:0]  fb_pixel,
	output logic [5:0]  fb_color
);

	logic [7:0] line_r;   // the line being rendered

	// ---- record register + combinational decode chain ----
	// rec_q re-registers the record RAM's output before the decode chain.
	// The frame engine ran the same chain from rf_word_* FABRIC registers,
	// which the fitter places next to the decode logic; an M10K's Q has a
	// fixed location and pays its routing BEFORE the same logic depth --
	// running the chain straight off rec_data was a ~400-path failing group.
	// The hop costs no time: S_REC_WAIT already exists for the RAM read, so
	// rec_q loads there and S_CAPTURE decodes from it, same two cycles.
	logic [63:0] rec_q;
	always_ff @(posedge clk) rec_q <= rec_data;

	logic [15:0] rw_y, rw_x, rw_attr, rw_code_lo;
	assign {rw_y, rw_x, rw_attr, rw_code_lo} = rec_q;

	logic [3:0]        rd_zoom_y_raw, rd_zoom_x_raw, rd_ny, rd_nx;
	logic signed [9:0] rd_y_pos, rd_x_pos;
	logic               rd_flip_y, rd_flip_x;
	logic [5:0]        rd_color;
	logic [16:0]       rd_code;

	sprite_record_decode u_record_decode (
		.word_y(rw_y), .word_x(rw_x), .word_attr(rw_attr), .word_code_lo(rw_code_lo),
		.zoom_y_raw(rd_zoom_y_raw), .zoom_x_raw(rd_zoom_x_raw), .ny(rd_ny), .nx(rd_nx),
		.y_pos(rd_y_pos), .x_pos(rd_x_pos), .flip_y(rd_flip_y), .flip_x(rd_flip_x),
		.color(rd_color), .code(rd_code)
	);

	logic signed [9:0] pt_x_adj, pt_y_adj;
	logic [5:0]        pt_zoom_x_t, pt_zoom_y_t;

	sprite_pos_transform u_pos_transform (
		.x_pos(rd_x_pos), .y_pos(rd_y_pos), .nx(rd_nx), .ny(rd_ny),
		.zoom_x_raw(rd_zoom_x_raw), .zoom_y_raw(rd_zoom_y_raw),
		.x_adj(pt_x_adj), .y_adj(pt_y_adj),
		.zoom_x_transformed(pt_zoom_x_t), .zoom_y_transformed(pt_zoom_y_t)
	);

	logic [4:0]  zl_dst_size_x, zl_dst_size_y;
	logic [16:0] zl_dx_x, zl_dx_y;

	sprite_zoom_lut u_zoom_lut_x (.raw_zoom(rd_zoom_x_raw), .dst_size(zl_dst_size_x), .dx(zl_dx_x));
	sprite_zoom_lut u_zoom_lut_y (.raw_zoom(rd_zoom_y_raw), .dst_size(zl_dst_size_y), .dx(zl_dx_y));

	// ---- per-sprite constants, registered once per hit ----
	logic [3:0]        a_nx, a_ny;
	logic              a_flip_x, a_flip_y;
	logic [5:0]        a_color;
	logic [16:0]       a_code;
	logic signed [9:0] a_x_adj, a_y_adj;
	logic [5:0]        a_zoom_x_t, a_zoom_y_t;
	logic [4:0]        a_dst_size_x, a_dst_size_y;
	logic [16:0]       a_dx_x, a_dx_y;

	// ---- sub-tile stepping (identical to the parked engine) ----
	logic [3:0] ix, iy;
	logic [5:0] subtile_ordinal;
	logic [3:0] dst_row;

	logic signed [9:0] st_sub_x, st_sub_y;
	logic [16:0]       st_sub_code;

	// Visitation is row-major, so the ordinal for an arbitrary (ix,iy) is
	// iy*nx + ix -- the frame engine could just count because it visited
	// every sub-tile; here we jump straight to the row containing the line.
	//
	// ord_prod is 8 bits and BOTH operands are widened to 8 before the
	// multiply, deliberately. This was written as
	//     6'({iy * a_nx}) + 6'({2'd0, ix})
	// which is wrong: the operands of a concatenation are self-determined,
	// so `iy * a_nx` was evaluated at max(4,4) = 4 BITS and wrapped mod 16
	// before the 6' cast ever saw it. The outer cast looks like it sets the
	// width and does not. Large sprites therefore re-used tile codes from
	// their own top rows -- nx=8 gave ordinals 0,8,0,8,... (a two-row
	// repeat), nx=6 gave 0,6,12,2,8,14,4,10 (everything inside the top ~2.7
	// rows) -- while any sprite with iy*nx < 16 was unaffected, which is why
	// small sprites looked perfect. Seen on hardware as large sprites drawing
	// similar-but-wrong tiles. Max value is 7*8+7 = 63, so 8 bits is ample
	// and the [5:0] slice cannot lose anything.
	// subtile_ordinal is a REGISTER, not a combinational product. Computing
	// it as iy*a_nx + ix in the same cycle it is used put the multiply
	// directly into lut_addr's path, which runs off-module to the spritelut
	// SDRAM bridge -- 582 failing paths (a_nx -> u_lut_bridge|tag_inflight)
	// in the first build after the width fix. The frame engine never had
	// this problem because it only ever incremented a counter; the line
	// engine additionally has to JUMP to the start of the hit row, so the
	// multiply is kept but retimed: ord_prod is evaluated off the registered
	// iy/a_nx and loaded into the ordinal at the S_FIND_ROW hit (a plain
	// register-to-register path for a 4x4 multiply), and the S_COL walk then
	// just increments, exactly like the frame engine.
	logic [7:0] ord_prod;
	assign ord_prod = {4'd0, iy} * {4'd0, a_nx};

	sprite_subtile_step u_subtile_step (
		.ix(ix), .iy(iy), .nx(a_nx), .ny(a_ny), .flip_x(a_flip_x), .flip_y(a_flip_y),
		.x_adj(a_x_adj), .y_adj(a_y_adj),
		.zoom_x_transformed(a_zoom_x_t), .zoom_y_transformed(a_zoom_y_t),
		.subtile_ordinal(subtile_ordinal), .code_base(a_code),
		.sub_x(st_sub_x), .sub_y(st_sub_y), .sub_code(st_sub_code)
	);

	// STAGE-B REGISTER, ported from the frame engine: st_sub_x feeds the
	// S_COL onscreen check through the sub-tile multiply, and consuming it
	// raw put that whole cone in series with the fb_* write enables -- the
	// entire failing-path population of the first line-path build. ix (and
	// the a_* it multiplies with) settle at least four cycles before S_COL
	// re-reads them (S_LUT_WAIT + S_ROW_WAIT always intervene), so a
	// free-running register is settled well before use. st_sub_y stays RAW:
	// S_FIND_ROW consumes it in the same cycle iy changes.
	logic signed [9:0] st_sub_x_r;
	always_ff @(posedge clk) st_sub_x_r <= st_sub_x;

	assign lut_addr = st_sub_code & 17'h1FFFF;

	// Does this sub-tile row cover the line being rendered?
	//
	// The search must not contain the sub-tile multiply: iy changes every
	// cycle of S_FIND_ROW, and iy -> (dy_grid*zoom)>>1 -> compare -> next-iy
	// is a single-cycle feedback loop that was the worst path of the second
	// line-path build. sub_y steps by exactly +/-zoom_y_t per row (the >>1
	// happens after accumulation, so this is bit-exact against the
	// multiply), so acc_y tracks dy_grid*zoom_y_t with one add per step;
	// the one real multiply runs once per sprite in S_FIND_INIT, off
	// registered operands. dy_grid*zoom <= 7*32 = 224, so 8 bits.
	logic [7:0] acc_y;
	logic signed [9:0] sub_y_search;
	assign sub_y_search = a_y_adj + $signed({3'd0, acc_y[7:1]});
	logic signed [10:0] row_off;
	assign row_off = $signed({line_r[7], 3'd0, line_r}) - $signed({sub_y_search[9], sub_y_search});
	wire row_hit = (row_off >= 0) && (row_off < $signed({6'd0, a_dst_size_y}));

	// ---- gfx row fetch ----
	logic [15:0] tile_code_r;
	logic [3:0]  zsi_src_row;

	sprite_zoom_src_index u_zsi_y (
		.col(dst_row), .dst_size(a_dst_size_y[3:0]), .dx(a_dx_y), .flip(a_flip_y), .src_index(zsi_src_row)
	);

	assign gfxrom_addr = {tile_code_r, zsi_src_row, 3'b000};

	// ---- fetched rows, waiting to be drawn ----
	// The fetch side (the FSM below) pushes each sub-tile row as it arrives and goes straight on
	// to the next sub-tile; the draw side pops rows and writes 16 pixels each. A row's fetch (the
	// spritelut word on Port 2, then the gfx granule on Port 1) overlaps the drawing of the rows
	// before it, so a row costs the longer of the two, not their sum. A fetch starts only with a
	// free entry, so its row always has one when it arrives. Rows are pushed and drawn in list
	// order, so a later sprite still overwrites an earlier one.
	localparam int DEPTH = 2;
	logic [63:0]       f_bytes [0:DEPTH-1];
	logic signed [9:0] f_x     [0:DEPTH-1];
	logic              f_flip  [0:DEPTH-1];
	logic [5:0]        f_color [0:DEPTH-1];
	logic [0:0]        f_wr, f_rd;
	logic [1:0]        f_count;
	wire               f_space = (f_count < DEPTH);

	// ---- draw side ----
	// Stage 1 picks the column's pixel (gfx_16x16x4_packed_msb: pixel p is bits 63-4p of the
	// granule) and its screen X; stage 2 writes it if it is on screen and not pen 0.
	logic              d_active;
	logic [63:0]       d_bytes;
	logic signed [9:0] d_x;
	logic              d_flip;
	logic [5:0]        d_color;
	logic [3:0]        d_col;
	wire  [3:0]        d_src = d_flip ? 4'd15 - d_col : d_col;
	wire  [3:0]        d_pix = d_bytes[63 - 4 * d_src -: 4];
	wire signed [10:0] d_sx  = $signed({d_x[9], d_x}) + $signed({7'd0, d_col});

	logic       px_valid, px_onscreen;
	logic [3:0] px_pixel;
	logic [8:0] px_x;
	logic [5:0] px_color;

	// ---- scan pipeline ----
	// scan_addr issues one index per cycle; scan_ytest answers for the index
	// issued the PREVIOUS cycle (registered BRAM read). idx_d/idx_d_valid
	// track which index the current scan_ytest word describes.
	logic [9:0]  idx;        // next index to issue
	logic [9:0]  idx_d;      // index scan_ytest currently describes
	logic         idx_d_valid;

	assign scan_addr = idx;
	assign rec_addr   = idx_d;

	logic signed [10:0] scan_off;
	assign scan_off = $signed({3'd0, line_r}) - $signed({scan_ytest[17], scan_ytest[17:8]});
	wire scan_hit = idx_d_valid && (scan_off >= 0)
	              && (scan_off < $signed({3'd0, scan_ytest[7:0]}));

	// ---- FSM ----
	typedef enum logic [3:0] {
		S_IDLE, S_SCAN, S_REC_WAIT, S_CAPTURE, S_FIND_INIT, S_FIND_ROW, S_ISSUE, S_LUT_WAIT, S_ROW_WAIT
	} state_t;
	state_t state;

	wire drawing = d_active || (f_count != 2'd0) || px_valid || fb_we;
	assign busy = (state != S_IDLE) || drawing;

	// Hard resync: line_tick while rendering aborts the line. The draw side stops that cycle and
	// its queue empties (a write registered from it would land after sprite_line_buffer swaps
	// banks, in the next line). The fetch side drains any in-flight req/valid -- the response
	// for a request already issued MUST be consumed, or it would pair with the NEXT line's first
	// request -- and parks in S_IDLE before the gated line_start (after the line buffer's clear).
	logic aborting;

	// a row arriving this cycle
	wire push = (state == S_ROW_WAIT) && gfxrom_valid && !aborting && !line_tick;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state       <= S_IDLE;
			lut_req     <= 1'b0;
			gfxrom_req  <= 1'b0;
			fb_we        <= 1'b0;
			px_valid     <= 1'b0;
			ovr_ev       <= 1'b0;
			aborting    <= 1'b0;
			line_r       <= 8'd0;
			idx           <= 10'd0;
			idx_d         <= 10'd0;
			idx_d_valid <= 1'b0;
			ix            <= 4'd0;
			iy            <= 4'd0;
			subtile_ordinal <= 6'd0;
			dst_row      <= 4'd0;
			tile_code_r <= 16'd0;
			a_nx <= 4'd1; a_ny <= 4'd1; a_flip_x <= 1'b0; a_flip_y <= 1'b0;
			a_color <= 6'd0; a_code <= 17'd0;
			a_x_adj <= 10'sd0; a_y_adj <= 10'sd0;
			a_zoom_x_t <= 6'd32; a_zoom_y_t <= 6'd32;
			a_dst_size_x <= 5'd16; a_dst_size_y <= 5'd16;
			a_dx_x <= 17'd0; a_dx_y <= 17'd0;
			f_wr <= '0; f_rd <= '0; f_count <= 2'd0;
			d_active <= 1'b0; d_col <= 4'd0;
		end else begin
			fb_we    <= 1'b0;
			px_valid <= 1'b0;
			ovr_ev   <= 1'b0;

			// ---- draw side ----
			// stage 2: the write for the column stage 1 picked last cycle; transpen(..., 0)
			if (px_valid && px_onscreen && px_pixel != 4'd0 && !line_tick) begin
				fb_we    <= 1'b1;
				fb_x     <= px_x;
				fb_pixel <= px_pixel;
				fb_color <= px_color;
			end

			if (line_tick) begin
				d_active <= 1'b0;
				f_wr     <= '0;
				f_rd     <= '0;
				f_count  <= 2'd0;
			end else begin
				// stage 1, and the queue
				logic pop;
				pop = 1'b0;
				if (d_active) begin
					px_valid    <= 1'b1;
					px_onscreen <= (d_sx >= 0) && (d_sx < 11'sd308);
					px_pixel    <= d_pix;
					px_x        <= d_sx[8:0];
					px_color    <= d_color;
					d_col       <= d_col + 4'd1;
					if (d_col == 4'd15) begin
						if (f_count != 2'd0) pop = 1'b1;
						else                 d_active <= 1'b0;
					end
				end else if (f_count != 2'd0) begin
					pop = 1'b1;
				end
				if (pop) begin
					d_active <= 1'b1;
					d_col    <= 4'd0;
					d_bytes  <= f_bytes[f_rd];
					d_x      <= f_x[f_rd];
					d_flip   <= f_flip[f_rd];
					d_color  <= f_color[f_rd];
					f_rd     <= f_rd + 1'b1;
				end
				if (push) begin
					f_bytes[f_wr] <= gfxrom_data;
					f_x[f_wr]     <= st_sub_x_r;
					f_flip[f_wr]  <= a_flip_x;
					f_color[f_wr] <= a_color;
					f_wr          <= f_wr + 1'b1;
				end
				f_count <= f_count + {1'b0, push} - {1'b0, pop};
			end

			// ---- fetch side ----
			if (line_tick && busy) ovr_ev <= 1'b1;        // the line under construction is cut short
			if (line_tick && state != S_IDLE) aborting <= 1'b1;

			if (aborting || (line_tick && state != S_IDLE)) begin
				// drain: hold an outstanding request until its response
				// arrives, consume it, then park. States without a request
				// in flight park immediately.
				if (lut_req) begin
					if (lut_valid) begin
						lut_req  <= 1'b0;
						aborting <= 1'b0;
						state     <= S_IDLE;
					end
				end else if (gfxrom_req) begin
					if (gfxrom_valid) begin
						gfxrom_req <= 1'b0;
						aborting    <= 1'b0;
						state        <= S_IDLE;
					end
				end else begin
					aborting <= 1'b0;
					state     <= S_IDLE;
				end
			end else begin
				case (state)
					S_IDLE: begin
						if (line_start) begin
							line_r       <= render_line;
							idx           <= 10'd0;
							idx_d_valid <= 1'b0;
							state         <= S_SCAN;
						end
					end

					// One candidate per cycle: test the ytest word for idx_d
					// while issuing idx. On a hit the scan has already issued
					// idx, so idx is exactly the resume point.
					S_SCAN: begin
						if (scan_hit) begin
							// rec_addr = idx_d is already presented; the
							// record word arrives after S_REC_WAIT
							idx_d_valid <= 1'b0;
							state         <= S_REC_WAIT;
						end else if ({1'b0, idx} == count) begin
							// count==0 arrives here immediately (idx_d_valid
							// still clear suppresses any phantom hit)
							idx_d_valid <= 1'b0;
							state         <= S_IDLE;
						end else begin
							idx_d         <= idx;
							idx_d_valid <= 1'b1;
							idx           <= idx + 10'd1;
						end
					end

					S_REC_WAIT: begin
						// rec_data valid next cycle
						state <= S_CAPTURE;
					end

					S_CAPTURE: begin
						a_nx          <= rd_nx;
						a_ny          <= rd_ny;
						a_flip_x      <= rd_flip_x;
						a_flip_y      <= rd_flip_y;
						a_color       <= rd_color;
						a_code        <= rd_code;
						a_x_adj       <= pt_x_adj;
						a_y_adj       <= pt_y_adj;
						a_zoom_x_t    <= pt_zoom_x_t;
						a_zoom_y_t    <= pt_zoom_y_t;
						a_dst_size_x <= zl_dst_size_x;
						a_dst_size_y <= zl_dst_size_y;
						a_dx_x        <= zl_dx_x;
						a_dx_y        <= zl_dx_y;
						ix             <= 4'd0;
						state          <= S_FIND_INIT;
					end

					// One cycle for the per-sprite multiply to settle into acc_y
					// (top-down search: dy_grid starts at ny-1 unflipped, 0
					// flipped -- see sprite_subtile_step's dy_grid mapping).
					S_FIND_INIT: begin
						iy     <= a_ny - 4'd1;
						acc_y <= a_flip_y ? 8'd0
						        : 8'(({4'd0, a_ny - 4'd1} * {2'd0, a_zoom_y_t}));
						state  <= S_FIND_ROW;
					end

					// Exact search for the sub-tile row covering line_r, walked from the highest
					// row down. The coarse scan can be conservatively wrong; a full miss here
					// just resumes the scan.
					S_FIND_ROW: begin
						if (row_hit) begin
							dst_row          <= row_off[3:0];
							ix                <= 4'd0;
							subtile_ordinal <= ord_prod[5:0];   // iy*nx + 0
							state             <= S_ISSUE;
						end else if (iy == 4'd0) begin
							state <= S_SCAN;   // false hit -- resume scan at idx
						end else begin
							iy     <= iy - 4'd1;
							// iy down => dy_grid down (unflipped) / up (flipped)
							acc_y <= a_flip_y ? acc_y + {2'd0, a_zoom_y_t}
							                   : acc_y - {2'd0, a_zoom_y_t};
						end
					end

					// a sub-tile's fetch starts once its row has an entry to land in
					S_ISSUE: begin
						if (f_space) begin
							lut_req <= 1'b1;
							state   <= S_LUT_WAIT;
						end
					end

					S_LUT_WAIT: begin
						if (lut_valid) begin
							tile_code_r <= lut_data;
							lut_req      <= 1'b0;
							gfxrom_req  <= 1'b1;
							state         <= S_ROW_WAIT;
						end
					end

					// the row is pushed (`push`); go on to the next sub-tile column
					S_ROW_WAIT: begin
						if (gfxrom_valid) begin
							gfxrom_req <= 1'b0;
							if (ix != a_nx - 4'd1) begin
								ix                <= ix + 4'd1;
								subtile_ordinal <= subtile_ordinal + 6'd1;
								state             <= S_ISSUE;
							end else begin
								state <= S_SCAN;          // sprite done -- resume scan
							end
						end
					end

					default: state <= S_IDLE;
				endcase
			end
		end
	end

endmodule
