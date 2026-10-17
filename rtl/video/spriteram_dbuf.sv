// Sprite RAM (0x400000-0x401FFF) and the copy the sprites are drawn from: dreamwld.cpp's
// screen_vblank copies sprite RAM to m_spritebuf[0] at vblank start, and draw_sprites reads
// only that copy.
//
// The CPU sees one persistent RAM. copy_start copies its first 2048 words -- the 0x1000 bytes
// draw_sprites reads -- into the snapshot, one word a clk; copy_busy is high meanwhile. The
// copy is not instantaneous as MAME's is, so dreamworld_core holds the 68020's sprite RAM
// accesses until it ends: the game writes the next list from the first lines after vblank
// start (docs/write_timing_mame.txt).
//
// A bank swap is not equivalent: under ping-pong the CPU writes bank A one frame and bank B
// the next, so an entry it does not rewrite every frame reads back what it held two frames
// ago (docs/LESSONS_LEARNED.md).
module spriteram_dbuf (
	input  logic clk,
	input  logic reset,

	input  logic copy_start,    // pulse: refresh the snapshot from the live RAM
	output logic copy_busy,     // 1 while the snapshot is being written

	// CPU-facing port -- the live RAM
	input  logic [11:0] cpu_addr,
	input  logic         cpu_wel,
	input  logic         cpu_weh,
	input  logic [15:0] cpu_wdata,
	output logic [15:0] cpu_rdata,

	// render-facing port -- the snapshot; meaningless while copy_busy
	input  logic [11:0] at_addr,
	output logic [15:0] at_data
);

	localparam int COPY_WORDS = 2048;

	// copy_rd_addr is presented to the live RAM's port B; the word arrives one cycle later
	// and is written to the snapshot at copy_wr_addr, which trails by that cycle.
	logic         copying;
	logic [10:0] copy_rd_addr;
	logic [10:0] copy_wr_addr;
	logic         copy_wr_en;

	assign copy_busy = copying | copy_wr_en;

	logic [15:0] live_b_rdata;

	dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_live (
		.clk(clk),
		.a_addr(cpu_addr),
		.a_wel(cpu_wel),
		.a_weh(cpu_weh),
		.a_wdata(cpu_wdata),
		.a_rdata(cpu_rdata),
		.b_addr({1'b0, copy_rd_addr}),
		.b_rdata(live_b_rdata)
	);

	dpram #(.ADDR_WIDTH(11), .DATA_WIDTH(16)) u_snap (
		.clk(clk),
		.a_addr(copy_wr_en ? copy_wr_addr : at_addr[10:0]),
		.a_wel(copy_wr_en),
		.a_weh(copy_wr_en),
		.a_wdata(live_b_rdata),
		.a_rdata(at_data),
		.b_addr(11'd0),
		.b_rdata()
	);

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			copying      <= 1'b0;
			copy_rd_addr <= 11'd0;
			copy_wr_addr <= 11'd0;
			copy_wr_en   <= 1'b0;
		end else begin
			copy_wr_en <= 1'b0;
			if (copy_start) begin
				copying      <= 1'b1;
				copy_rd_addr <= 11'd0;
			end else if (copying) begin
				copy_wr_en   <= 1'b1;
				copy_wr_addr <= copy_rd_addr;
				if (copy_rd_addr == COPY_WORDS - 1) copying      <= 1'b0;
				else                                 copy_rd_addr <= copy_rd_addr + 11'd1;
			end
		end
	end

endmodule
