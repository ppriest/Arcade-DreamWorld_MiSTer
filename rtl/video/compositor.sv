// Mixing, dreamwld.cpp screen_update: layer 0 (opaque), then layer 1 (pen 0 transparent),
// then sprites (pen 0 transparent, already applied by the sprite engine, so sp_present means
// a drawn pixel). There are no priority bits.
//
// Palette indices (GFXDECODE gfx_dreamwld): sprites 0x000 + colour*16 + pen, 64 colours;
// tiles 0x800 + colour*16 + pen, where the colour already carries layer 1's +0x40.
//
// Combinational. Two palette reads run in parallel -- the live palette for tiles (pal_addr)
// and the mirror of entries 0x000-0x3FF for sprites (pal_s_addr) -- and dreamworld_core
// applies sprite_sel to their outputs a cycle later. backdrop_black is set when nothing is
// drawn: a layer disabled from the debug page, or a tile fetch that did not arrive in time.

module compositor (
	input  logic         l0_valid,
	input  logic [3:0]  l0_pixel,
	input  logic [6:0]  l0_color,
	input  logic         l0_enable,

	input  logic         l1_valid,
	input  logic [3:0]  l1_pixel,
	input  logic [6:0]  l1_color,
	input  logic         l1_enable,

	input  logic         sp_present,
	input  logic [3:0]  sp_pixel,
	input  logic [5:0]  sp_color,

	output logic [11:0] pal_addr,
	output logic [9:0]  pal_s_addr,
	output logic         sprite_sel,
	output logic         backdrop_black
);

	wire l0_draws = l0_valid && l0_enable;
	wire l1_draws = l1_valid && l1_enable && (l1_pixel != 4'd0);

	assign pal_addr       = 12'h800 + {1'b0, l1_draws ? {l1_color, l1_pixel} : {l0_color, l0_pixel}};
	assign pal_s_addr     = {sp_color, sp_pixel};
	assign sprite_sel     = sp_present;
	assign backdrop_black = !l1_draws && !l0_draws;

endmodule
