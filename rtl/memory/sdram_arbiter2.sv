// SPDX-License-Identifier: GPL-3.0-or-later
// Routes two read-only req/valid consumers onto one sdram_phy port: fixed-pointer round robin, the
// served consumer rotating to the back, so sustained pressure from one cannot starve the other.
//
// One instance, on Port 0, arbitrating tilemap layer 0 against layer 1 gfxrom. The sprite gfxrom has
// its own port (Port 1) and the spritelut sits on sdram_arbiter6.
//
// Both consumers HOLD req until the matching valid: a one-shot pulse would be lost while the arbiter
// was busy serving the other.

module sdram_arbiter2 (
	input  logic clk,
	input  logic reset,

	// physical port (to sdram_phy)
	output logic         phy_req,
	output logic [24:0] phy_addr,
	input  logic         phy_busy,
	input  logic         phy_valid,
	input  logic [63:0] phy_rdata,

	// consumer 0
	input  logic         c0_req,
	input  logic [24:0] c0_addr,
	output logic         c0_valid,
	output logic [63:0] c0_data,

	// consumer 1
	input  logic         c1_req,
	input  logic [24:0] c1_addr,
	output logic         c1_valid,
	output logic [63:0] c1_data
);

	typedef enum logic [1:0] {A_IDLE, A_ISSUE, A_WAIT} astate_t;
	astate_t astate;

	logic sel;       // 0 = consumer 0, 1 = consumer 1
	logic rr_ptr;    // which consumer round-robin favors next

	logic next_sel;
	logic found;
	always_comb begin
		if (rr_ptr == 1'b0) begin
			if      (c0_req) begin next_sel = 1'b0; found = 1'b1; end
			else if (c1_req) begin next_sel = 1'b1; found = 1'b1; end
			else              begin next_sel = 1'b0; found = 1'b0; end
		end else begin
			if      (c1_req) begin next_sel = 1'b1; found = 1'b1; end
			else if (c0_req) begin next_sel = 1'b0; found = 1'b1; end
			else              begin next_sel = 1'b0; found = 1'b0; end
		end
	end

	assign phy_addr = sel ? c1_addr : c0_addr;
	assign phy_req  = (astate == A_ISSUE) && !phy_busy;

	assign c0_valid = (astate == A_WAIT) && !sel && phy_valid;
	assign c1_valid = (astate == A_WAIT) &&  sel && phy_valid;
	assign c0_data  = phy_rdata;
	assign c1_data  = phy_rdata;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			astate <= A_IDLE;
			rr_ptr <= 1'b0;
		end else begin
			case (astate)
				A_IDLE: begin
					if (found) begin
						sel    <= next_sel;
						astate <= A_ISSUE;
					end
				end

				A_ISSUE: begin
					if (!phy_busy) astate <= A_WAIT;
				end

				A_WAIT: begin
					if (phy_valid) begin
						rr_ptr <= ~sel;
						astate <= A_IDLE;
					end
				end

				default: ;
			endcase
		end
	end

endmodule
