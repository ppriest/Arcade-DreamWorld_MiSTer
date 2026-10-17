// Per-frame sprite list build pass, for the per-scanline sprite renderer.
//
// Walking all 512 records, fetching and decoding each one, on every line would cost about 10
// cycles a sprite a line. This module does it once a frame, after the vblank copy, and keeps
// only the sprites whose box reaches the screen, so the per-line cost is one cycle per
// candidate plus the drawing.
//
// At build_start it walks records 0-511 of the snapshot in order (dreamwld.cpp draw_sprites:
// the first 0x1000 bytes, two longs a record) and stores, in that order -- later entries
// overwrite earlier ones -- one entry per sprite whose box touches the screen:
//
//   ytest RAM (18 bits): { y_top[9:0] signed, span_y[7:0] }
//   rec RAM   (64 bits): { word_y, word_x, word_attr, word_code_lo }
//
// The box comes from the same math sprite_subtile_step uses (zoom is always 0 here, so it is
// 16 pixels a tile). The engine's FIND_ROW re-does the exact per-row test on every hit.
//
// Budget: 512 records x ~9 cycles ~= 4.6K cycles, after the 2K-cycle copy, against vblank's
// 39 lines x 3552. The engine never scans while build_busy (dreamworld_core gates its start).

module sprite_line_list (
	input  logic clk,
	input  logic reset,

	input  logic         build_start,   // pulse: rebuild the table from the snapshot
	output logic         build_busy,
	output logic         build_done,     // pulse: table + count are coherent

	// snapshot read port (records at word offsets 0x000-0x7FF)
	output logic [11:0] at_addr,
	input  logic [15:0] at_data,

	// engine-facing table read ports (1-cycle sync reads)
	input  logic [9:0]  scan_addr,
	output logic [17:0] scan_ytest,    // { y_top[9:0] signed, span_y[7:0] }
	input  logic [9:0]  rec_addr,
	output logic [63:0] rec_data,       // { word_y, word_x, word_attr, word_code_lo }

	output logic [10:0] count            // entries stored by the last completed build
);

	// ---- record fetch, driven by a linear walk ----
	logic [9:0] n;   // record being walked, 0-512

	logic        rf_start, rf_busy, rf_record_valid;
	logic [15:0] rf_word_y, rf_word_x, rf_word_attr, rf_word_code_lo;

	sprite_record_fetch u_record_fetch (
		.clk(clk), .reset(reset),
		.start(rf_start), .sprite_index(n), .busy(rf_busy),
		.sram_addr(at_addr), .sram_data(at_data),
		.record_valid(rf_record_valid),
		.word_y(rf_word_y), .word_x(rf_word_x), .word_attr(rf_word_attr), .word_code_lo(rf_word_code_lo)
	);

	// ---- combinational decode, only as far as the bounding box needs ----
	logic [3:0]        rd_zoom_y_raw, rd_zoom_x_raw, rd_ny, rd_nx;
	logic signed [9:0] rd_y_pos, rd_x_pos;
	logic               rd_flip_y, rd_flip_x;
	logic [5:0]        rd_color;
	logic [16:0]       rd_code;

	sprite_record_decode u_record_decode (
		.word_y(rf_word_y), .word_x(rf_word_x), .word_attr(rf_word_attr), .word_code_lo(rf_word_code_lo),
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

	// Decoded position, zoom and size, registered in S_FETCH so the bounding
	// box below is computed from registers in S_TEST. In one cycle,
	// rf_word_* -> decode -> position transform -> span multiply -> box adds
	// and compares -> wr_en was a failing path of the release build (-0.151ns,
	// 9f70427 at seed 8). Costs one cycle per sprite, in vblank.
	logic [3:0]        q_ny, q_nx;
	logic signed [9:0] q_y_adj, q_x_adj;
	logic [5:0]        q_zoom_y_t, q_zoom_x_t;
	logic [4:0]        q_dst_size_y, q_dst_size_x;

	// Bounding box. (ny-1)*zoom_y_t is at most 7*32=224; >>1 is 112; plus
	// dst_size_y (<=16) gives span <= 128, comfortably 8 bits. Same for X
	// against its 9-bit span.
	logic [7:0] span_y_c;
	logic [8:0] span_x_c;
	assign span_y_c = 8'((({4'd0, q_ny - 4'd1} * {2'd0, q_zoom_y_t}) >> 1) + {3'd0, q_dst_size_y});
	assign span_x_c = 9'((({4'd0, q_nx - 4'd1} * {2'd0, q_zoom_x_t}) >> 1) + {4'd0, q_dst_size_x});

	logic signed [10:0] y_bot_c, x_rgt_c;
	assign y_bot_c = $signed({q_y_adj[9], q_y_adj}) + $signed({3'd0, span_y_c});
	assign x_rgt_c = $signed({q_x_adj[9], q_x_adj}) + $signed({2'd0, span_x_c});

	wire box_visible = (y_bot_c > 0) && ($signed({q_y_adj[9], q_y_adj}) < 11'sd224)
	                 && (x_rgt_c > 0) && ($signed({q_x_adj[9], q_x_adj}) < 11'sd308);

	// ---- table RAMs ----
	logic [17:0] ytest_ram [0:1023];
	logic [63:0] rec_ram   [0:1023];

	logic         wr_en;
	logic [9:0]  wr_idx;
	logic [17:0] wr_ytest;
	logic [63:0] wr_rec;

	always_ff @(posedge clk) begin
		if (wr_en) ytest_ram[wr_idx] <= wr_ytest;
		scan_ytest <= ytest_ram[scan_addr];
	end

	always_ff @(posedge clk) begin
		if (wr_en) rec_ram[wr_idx] <= wr_rec;
		rec_data <= rec_ram[rec_addr];
	end

	// ---- build FSM ----
	// One registered stage between record_valid and the table write keeps
	// the whole decode chain out of the RAM-write timing path.
	typedef enum logic [2:0] {S_IDLE, S_WALK, S_FETCH, S_TEST, S_STORE} state_t;
	state_t state;

	assign build_busy = (state != S_IDLE);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state       <= S_IDLE;
			n           <= 10'd0;
			rf_start    <= 1'b0;
			build_done <= 1'b0;
			wr_en        <= 1'b0;
			wr_idx      <= 10'd0;
			wr_ytest    <= 18'd0;
			wr_rec       <= 64'd0;
			count        <= 11'd0;
		end else begin
			rf_start    <= 1'b0;
			build_done <= 1'b0;
			wr_en        <= 1'b0;

			case (state)
				S_IDLE: begin
					if (build_start) begin
						n       <= 10'd0;
						wr_idx  <= 10'd0;
						state   <= S_WALK;
					end
				end

				S_WALK: begin
					if (n == 10'd512) begin
						count       <= {1'b0, wr_idx};
						build_done <= 1'b1;
						state        <= S_IDLE;
					end else begin
						rf_start <= 1'b1;
						state     <= S_FETCH;
					end
				end

				S_FETCH: begin
					if (rf_record_valid) begin
						// decode and position transform settle from the
						// just-latched rf_word_* registers; register them for
						// the box test
						q_ny          <= rd_ny;
						q_nx          <= rd_nx;
						q_y_adj       <= pt_y_adj;
						q_x_adj       <= pt_x_adj;
						q_zoom_y_t    <= pt_zoom_y_t;
						q_zoom_x_t    <= pt_zoom_x_t;
						q_dst_size_y <= zl_dst_size_y;
						q_dst_size_x <= zl_dst_size_x;
						wr_rec        <= {rf_word_y, rf_word_x, rf_word_attr, rf_word_code_lo};
						state          <= S_TEST;
					end
				end

				S_TEST: begin
					wr_ytest <= {q_y_adj, span_y_c};
					wr_en     <= box_visible;
					state      <= S_STORE;
				end

				S_STORE: begin
					// wr_en wrote (or skipped) this entry on the edge entering
					// this state; next record either way
					if (wr_en) wr_idx <= wr_idx + 10'd1;
					n      <= n + 10'd1;
					state  <= S_WALK;
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
