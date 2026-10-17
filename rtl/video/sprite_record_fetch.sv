// Fetches one sprite's 4-word (8-byte) record from the sprite RAM snapshot: record n at word
// 4n, laid out Y/X/attr/code_lo (sprite_record_decode's port names). sprite_line_list walks
// n = 0-511. One synchronous read port, the 1-cycle read every BRAM interface here uses.

module sprite_record_fetch (
	input  logic clk,
	input  logic reset,

	input  logic         start,         // pulse: begin fetching sprite_index's record
	input  logic [9:0]  sprite_index,  // 0-511, sampled when start pulses
	output logic         busy,

	output logic [11:0] sram_addr,   // sprite_index*4 + 0..3
	input  logic [15:0] sram_data,   // 1-cycle sync read latency

	output logic         record_valid,  // pulses once, all 4 words latched
	output logic [15:0] word_y,
	output logic [15:0] word_x,
	output logic [15:0] word_attr,
	output logic [15:0] word_code_lo
);

	typedef enum logic [1:0] {S_IDLE, S_FETCH, S_LATCH} state_t;
	state_t state;

	logic [11:0] base_addr;
	logic [1:0]  word_sel;   // 0=Y, 1=X, 2=attr, 3=code_lo

	assign sram_addr = base_addr + {10'd0, word_sel};
	assign busy        = (state != S_IDLE);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state         <= S_IDLE;
			base_addr     <= 12'd0;
			word_sel      <= 2'd0;
			record_valid <= 1'b0;
			word_y         <= 16'd0;
			word_x         <= 16'd0;
			word_attr     <= 16'd0;
			word_code_lo <= 16'd0;
		end else begin
			record_valid <= 1'b0;

			case (state)
				S_IDLE: begin
					if (start) begin
						base_addr <= {sprite_index, 2'd0};  // sprite_index * 4
						word_sel  <= 2'd0;
						state      <= S_FETCH;
					end
				end

				S_FETCH: begin
					state <= S_LATCH;
				end

				S_LATCH: begin
					case (word_sel)
						2'd0: word_y         <= sram_data;
						2'd1: word_x         <= sram_data;
						2'd2: word_attr     <= sram_data;
						2'd3: word_code_lo <= sram_data;
					endcase

					if (word_sel == 2'd3) begin
						record_valid <= 1'b1;
						state         <= S_IDLE;
					end else begin
						word_sel <= word_sel + 2'd1;
						state     <= S_FETCH;
					end
				end

				default: state <= S_IDLE;
			endcase
		end
	end

endmodule
