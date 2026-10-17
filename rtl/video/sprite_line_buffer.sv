// Double-buffered 308-pixel sprite line buffer, one entry a screen column.
//
// The swap happens at line_start, in hblank, so it never tears a visible line, and a bank is
// cleared while it is neither displayed nor rendered into. The clear is W of the line's 3552
// clk (444 pixels at clk/8); the rest is the sprite engine's.
//
// Sequencing, driven by line_start:
//   1. swap banks -- the bank just displayed becomes the render bank
//   2. clear it (W cycles), holding `ready` low
//   3. raise `ready`; the sprite engine renders the NEXT line into it while
//      the other bank is displayed
//
// The clear is a separate pass rather than clear-on-read because read and
// clear would hit the same address in the same cycle, and inferred RAM's
// read-during-write behaviour is not something to depend on.

module sprite_line_buffer (
    input  logic clk,
    input  logic reset,

    // one pulse per scanline, during hblank
    input  logic line_start,
    output logic ready,          // render bank cleared, safe to write

    // write port -- sprite engine, rendering the NEXT line
    input  logic        we,
    input  logic [8:0]  wx,       // 0..307
    input  logic [3:0]  wpixel,
    input  logic [5:0]  wcolor,

    // read port -- compositor, displaying the CURRENT line
    input  logic [8:0]  rx,
    output logic        rd_present,
    output logic [3:0]  rd_pixel,
    output logic [5:0]  rd_color
);

    localparam int W = 308;

    // packed entry: {present(1), pixel(4), color(6)} = 11 bits
    logic [10:0] mem_a [0:W-1];
    logic [10:0] mem_b [0:W-1];

    logic bank;            // 0: A renders, B displays. 1: reversed.
    logic [8:0] clr_addr;
    logic        clearing;

    assign ready = ~clearing;

    // ---- write/clear mux, per bank ----
    // The render bank takes engine writes; the bank being cleared takes the
    // clear counter. They are the same bank -- clearing happens first, then
    // rendering -- so one write port each is enough.
    logic        wr_en;
    logic [8:0]  wr_addr;
    logic [10:0] wr_data;

    assign wr_en   = clearing ? 1'b1        : we;
    assign wr_addr = clearing ? clr_addr    : wx;
    assign wr_data = clearing ? 11'd0       : {1'b1, wpixel, wcolor};

    wire a_is_render = (bank == 1'b0);

    logic [10:0] a_rd, b_rd;
    always_ff @(posedge clk) begin
        if (wr_en &&  a_is_render) mem_a[wr_addr] <= wr_data;
        a_rd <= mem_a[rx];
    end
    always_ff @(posedge clk) begin
        if (wr_en && !a_is_render) mem_b[wr_addr] <= wr_data;
        b_rd <= mem_b[rx];
    end

    // Display reads the bank that is NOT being rendered. bank_d matches the
    // one-cycle latency of the registered reads above.
    logic bank_d;
    logic [10:0] rd_word;
    assign rd_word = (bank_d == 1'b0) ? b_rd : a_rd;

    assign rd_present  = rd_word[10];
    assign rd_pixel     = rd_word[9:6];
    assign rd_color     = rd_word[5:0];

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            bank      <= 1'b0;
            bank_d    <= 1'b0;
            clr_addr  <= 9'd0;
            clearing  <= 1'b1;      // clear once out of reset
        end else begin
            bank_d <= bank;

            if (line_start) begin
                bank     <= ~bank;
                clr_addr <= 9'd0;
                clearing <= 1'b1;
            end else if (clearing) begin
                if (clr_addr == W - 1) clearing <= 1'b0;
                else                     clr_addr <= clr_addr + 9'd1;
            end
        end
    end

endmodule
