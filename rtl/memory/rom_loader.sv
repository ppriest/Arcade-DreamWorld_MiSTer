// SPDX-License-Identifier: GPL-3.0-or-later
// Fast ROM loading: bulk copy from DDR3 into the SDRAM ROM map.
//
// With address="0x30000000" on the .mra's <rom index="0">, the HPS DMAs the ROM straight into
// DDR3 and the core sees ioctl_download assert and deassert with no ioctl_wr pulses at all; this
// copies DDR3 -> SDRAM with the core in reset, 8-byte granules in, four 16-bit words out. An .mra
// without the attribute still streams through ioctl and sdram_download, and the caller tells the
// two apart by whether any ioctl_wr arrived. (Mechanism from srg320/Arcade-PsikyoSH2_MiSTer.)
module rom_loader #(
	// Bytes to copy: the whole SDRAM ROM map (dreamworld_sdram_top.sv). Copying
	// it unconditionally means no set's real length has to be known, at the cost
	// of the padding's copy time.
	parameter logic [27:0] LENGTH = 28'h1280000
) (
	input  logic clk,
	input  logic reset,

	input  logic         start,   // pulse: begin the copy
	output logic         busy,    // 1 while copying; hold the core in reset

	// DDR3 read port (rtl/memory/ddram_phy.sv): 8-byte granules, byte offset
	// from the 0x30000000 HPS extra-RAM base the .mra loads to.
	output logic         ddr_req,
	output logic [27:0] ddr_addr,
	input  logic         ddr_busy,
	input  logic         ddr_valid,
	input  logic [63:0] ddr_rdata,

	// SDRAM write port -- same hold-until-busy contract as sdram_download's.
	output logic         dl_req,
	output logic [24:0] dl_addr,
	output logic [15:0] dl_data,
	output logic         dl_we16,
	input  logic         dl_busy
);

	typedef enum logic [2:0] {L_IDLE, L_RD, L_RDWAIT, L_WR, L_WRACK, L_NEXT} lstate_t;
	lstate_t state;

	logic [27:0] byte_addr;    // running offset, granule-aligned
	logic [63:0] gran;
	logic [1:0]  word_idx;     // which 16-bit word of the granule

	assign busy    = (state != L_IDLE);
	assign ddr_req = (state == L_RD);
	assign ddr_addr = byte_addr;
	assign dl_req  = (state == L_WR);
	assign dl_we16 = 1'b1;     // both byte lanes, one SDRAM transaction per word
	assign dl_addr = 25'(byte_addr) + {23'd0, word_idx, 1'b0};

	// The granule arrives little-endian: ROM byte N sits at bit (N%8)*8, so
	// word k is simply gran[k*16 +: 16] and lands at byte_addr + k*2.
	always_comb begin
		unique case (word_idx)
			2'd0: dl_data = gran[15:0];
			2'd1: dl_data = gran[31:16];
			2'd2: dl_data = gran[47:32];
			2'd3: dl_data = gran[63:48];
		endcase
	end

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			state     <= L_IDLE;
			byte_addr <= 28'd0;
			word_idx  <= 2'd0;
		end else begin
			case (state)
				L_IDLE: if (start) begin
					byte_addr <= 28'd0;
					word_idx  <= 2'd0;
					state     <= L_RD;
				end

				// ddram_phy takes a pulse only while not busy
				L_RD: if (!ddr_busy) state <= L_RDWAIT;

				L_RDWAIT: if (ddr_valid) begin
					gran     <= ddr_rdata;
					word_idx <= 2'd0;
					state    <= L_WR;
				end

				// hold dl_req until the arbiter takes it, then until it frees
				L_WR:    if (dl_busy)  state <= L_WRACK;
				L_WRACK: if (!dl_busy) begin
					if (word_idx == 2'd3) state <= L_NEXT;
					else begin
						word_idx <= word_idx + 2'd1;
						state    <= L_WR;
					end
				end

				L_NEXT: begin
					if (byte_addr + 28'd8 >= LENGTH) state <= L_IDLE;
					else begin
						byte_addr <= byte_addr + 28'd8;
						state     <= L_RD;
					end
				end

				default: state <= L_IDLE;
			endcase
		end
	end

endmodule
