// SPDX-License-Identifier: GPL-3.0-or-later
// True dual-port word RAM: a byte-lane write port with registered read-before-write (the shape
// rtl/cpu/maincpu.sv uses for its BRAM regions), plus an independent read-only port for a second
// consumer -- a video engine reading the memory the CPU writes. One clock domain, so no CDC.
module dpram #(
	parameter int ADDR_WIDTH = 13,
	parameter int DATA_WIDTH = 16
) (
	input  logic                   clk,

	input  logic [ADDR_WIDTH-1:0] a_addr,
	input  logic                   a_wel,
	input  logic                   a_weh,
	input  logic [DATA_WIDTH-1:0] a_wdata,
	output logic [DATA_WIDTH-1:0] a_rdata,

	input  logic [ADDR_WIDTH-1:0] b_addr,
	output logic [DATA_WIDTH-1:0] b_rdata
);

	localparam int DEPTH = 1 << ADDR_WIDTH;

	logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

	always_ff @(posedge clk) begin
		a_rdata <= mem[a_addr];
		if (a_wel) mem[a_addr][7:0]            <= a_wdata[7:0];
		if (a_weh) mem[a_addr][DATA_WIDTH-1:8] <= a_wdata[DATA_WIDTH-1:8];
	end

	always_ff @(posedge clk) begin
		b_rdata <= mem[b_addr];
	end

endmodule
