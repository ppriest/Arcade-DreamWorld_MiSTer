# SemiCom 68EC020 (Dream World) — MiSTer Core Roadmap

**Approved, including the 54 MHz clock. A phase whose scope changes goes back for approval.**

## Context

Goal: a DE10-nano MiSTer core for the SemiCom 68EC020 board, emulated by MAME's
`src/mame/misc/dreamwld.cpp` with the `okim6295` and `mcs51` devices — a Quartus 17.0.2
SystemVerilog project producing one `.rbf` and a `.mra` per set.

The board is a copy of Psikyo's 68020 hardware (dreamwld.cpp lines 17-24), so the core starts from
Arcade-Psikyo_MiSTer: the 68EC020 on TG68K.C, the memory map's base, the per-scanline tilemap and
sprite engines, the SDRAM backend, fast DDR3 ROM loading, hiscore, CRT Adjust and HDMI rotation are
already built and running on hardware there. The Psikyo-only hardware has been removed (commit
`e3ecde7`). What is new work:

1. **Sound**: two OKI M6295 with a 2-bit bank register each — jt6295, vendored in five sibling cores.
2. **Protection MCU**: an 87C52/AT89C52 running its ROM — jt8051, vendored in Eolith and Vamphalf.
3. **Sprites**: a different format (no display list, no zoom, 6-bit colour, 17-bit tile through the
   LUT, positions wrapping at 512) in the Psikyo per-scanline engine.
4. **Video timing**: 308x224 at 57.793 Hz, pixel clock not known (see Clocks).

Everything else is adapting the inherited RTL with verification against MAME. Hardware facts with
sources are in [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md).

Cross-cutting findings from the previous cores are in **[`LESSONS_LEARNED.md`](LESSONS_LEARNED.md)**.
Working practice built on them is in **[`WORKFLOW.md`](WORKFLOW.md)**.

## Progress

**Phases 0-2 are done, and Phase 3's exit is met: all seven sets boot, take a coin and start
on a DE10-nano, silent, with the standard features in (Phase 3 results below). Open from Phase 3:
CRT Adjust, Scale and Crop and hiscore save on a display, baryon's coin with a controller.
Phase 4 (sound) is next, not started.**

- Phase 2 on hardware, stp `faf5c60`: 12 native screenshots across the attract sequence
  (`debug/hw/p2/s00`-`s11`), each matched against MAME frames 300-7200 by
  `scripts/hw_vs_mame.py`. 11 are identical to a MAME frame (sprites, both tilemaps, row scroll,
  palette). s04 matches frame 2939 from row 28 down; rows 0-5 match frame 2938 and rows 6-27 are
  a mix. Between 2938 and 2939 MAME changes 633 palette entries and nothing else (VRAM, scroll,
  row scroll equal; captures `debug/dreamwld-f2938`, `-f2939`), so the fade step's writes were
  still landing while the top lines were drawn.
- Phase 2 RTL (`d765647`, `bef36d8`): 308 columns from screen x 0, the tilemap offsets, the
  dreamwld sprite record and linear list, pen 0, 6-bit sprite colour, copy-then-build at vblank,
  a fixed-order compositor. `sim/frame_tb/run_scenes.py --default`: 12 of 12 scenes, both
  recorded frames each, identical to the model. The bench loads state with the 68020 paused,
  so writes during the frame (VRAM, palette, sprite RAM against the copy) are not exercised.
- Phase 2 model: `scripts/render_model.py` renders a `mame_capture.py` directory as dreamwld.cpp's
  `screen_update` does. `scripts/model_sweep.py`: seven scenes (four attract, three play) of each
  of the seven sets, 49 of 49 pixel-identical to MAME. Covered: per-line row scroll, tile bank 1,
  sprite x and y flip, sprites up to 8x8 tiles, wrap at 0x200. Not reached by any scene: the
  128x32 geometry (ctrl bit 10, "Test mode only" in the driver) and 16-line row scroll (bit 9).
- Phase 1 on hardware, stp `5345036`: the 68020's first 23 ROM reads match the ROM
  (`debug/hw/stp302_first128.png`, overlay), and the attract sequence cycles through its night
  and forest scenes (`debug/hw/stp302_t20.png`, `debug/hw/stp302_sheet.png`). Sprites are still
  decoded in Psikyo's format and take their transparent pen from Psikyo's sprite control word
  (`spriteram_dbuf.sv`); dreamwld.cpp always uses pen 0 (lines 249-252). Both are Phase 2. SDRAM_CLK
  needed 301.5 degrees: 180 sampled read beats on their boundary, 0 read 0000
  (`rtl/pll/pll_0002.v`, `docs/HACKS.md`).
- ISSP on the same build (`scripts/read_issp.py C` and `M`, counted from launch). dreamwld
  after 25 s: 1737 writes to C00020 and 1737 reads of C00030, 2272 interrupt acknowledges,
  1738 MCU latch loads. cutefght after 30 s: 1793 and 1793, 1957 acknowledges, 1794 latch loads,
  background drawn (`debug/hw/stp302_cutefght_t30.png`).
- `sim/boot_tb`, dreamwld: the first 50 ms match MAME's 34,223 writes. At 2.6 s, 1586 of 1737
  handshake bytes, none wrong, no interrupt yet (`debug/boot_tb_2600.log`). The first C00020
  write is at 1.188 s (MAME 0.95 s), and a byte takes 0.89 ms against MAME's 0.46 (frames
  55-101, `docs/boot_trace_mame.txt`). The cause of the difference is not measured. cutefght
  was not simulated; hardware covers it.

- `de225e3` imports Psikyo develop `5c68eb8` unchanged apart from renames; `e3ecde7` strips the
  Psikyo-only hardware (-32,800 lines) and decodes the layer control word and inputs per
  dreamwld.cpp.
- Hardware look at `42baf8e` (85.909 MHz build, `releases/_dev/Dream World.mra` on the Psikyo
  SDRAM map): all-black frames at 15 s and 45 s, where MAME shows the title and the attract demo.
  Cause, from MAME's trace: the vblank handler is the MCU stream copied to 0xFFD000, and C00030
  is not decoded (`docs/boot_trace_mame.txt`).
- Phase 0 results: `docs/write_timing_mame.txt`, `docs/sprite_load_mame.txt`,
  `docs/boot_trace_mame.txt`; `sim/mcu_tb` and `sim/oki_tb` pass; `57e1837` moves to 54 MHz.
- ModelSim (`scripts/run_sim.sh`) after `57e1837`: maincpu, vreg_decode, sdram,
  dreamworld_sdram_top, dreamworld_core, dreamworld_top, tilemap_line_engine/flip/rowscroll,
  compositor, spriteram_dbuf, mcu, oki pass. `video_pipeline_tb` and `video_timing_tb` failed
  before any change here (they use only imported, unchanged modules); `crt_chain_tb` did not
  finish in 300 s.
- Quartus, `build_staged.py`, release revision, default seed: `42baf8e` (85.909 MHz) met timing
  at +0.079 ns; `57e1837` (54 MHz) meets timing on every clock, worst `clk_sys` setup +5.123 ns;
  PLL VCO 540 MHz, both outputs 54.0 MHz, SDRAM_CLK at 180.00 degrees; 19,184 ALMs (46%),
  386 of 553 M10K (70%), 59 DSP. Not deployed: it still stops at the MCU handshake.

## Game scope

| Set | Parent | Config | maincpu | gfx1 | gfx2 | oki1 | oki2 | Rot |
|---|---|---|---|---|---|---|---|---|
| dreamwld | - | dreamwld | 1 MB | 2 MB | 2 MB | 512 KB | 512 KB | 0 |
| cutefght | - | dreamwld | 2 MB | 8 MB | 2 MB | 512 KB | 512 KB | 0 |
| baryon | - | baryon | 1 MB | 4 MB | 2 MB | 512 KB | - | 270 |
| baryona | baryon | baryon | 1 MB | 4 MB | 2 MB | 512 KB | - | 270 |
| rolcrush | - | baryon | 1 MB | 2 MB | 2 MB | 512 KB | empty | 0 |
| rolcrusha | rolcrush | baryon | 1 MB | 2 MB | 2 MB | 512 KB | empty | 0 |
| gaialast | - | baryon | 1 MB | 6 MB | 2 MB | 512 KB | empty | 0 |

All also load `mcu` 8 KB and `spritelut` 256 KB. All `good` in MAME.

### Scope decision

- **In scope:** all seven — one memory map, one screen, one chipset; the largest (cutefght,
  13.3 MB) fits the 32 MB SDRAM module.
- **First-target set:** dreamwld — the only set whose MCU ROM is a real dump.
- **Second target:** cutefght — the 2 MB program ROM and 8 MB of sprites.

## Hardware reality (from the driver, not assumption)

Details and line numbers: [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md).

### Chips

68EC020 16 MHz; AT89C52 16 MHz (MAME's value, "from docs"); OKI M6295 x1 or x2 at 1 MHz, pin 7
low; video in two Actel FPGAs.

### Clocks

Board: 32 MHz XTAL (CPU /2, MCU /2, OKI /32) and 27 MHz XTAL (not in the driver; the video).

**Decided: `clk_sys` 54 MHz = 27 MHz x 2, SDRAM on the same clock** (approved; `57e1837`).

| Clock | From 54 MHz | Exact |
|---|---|---|
| pixel 6.75 MHz (27/4) | `ce_pix` 1 in 8 | yes |
| 68EC020 16 MHz | Bresenham 8/27 (ticks 3-4 clocks apart) | yes |
| 87C52 16 MHz oscillator | 8/27 (`jt8052` needs an idle clock between enables) | yes |
| M6295 1 MHz | 1 in 54 | yes |
| SDRAM_CLK | 54 MHz, 180 degrees | - |

**Pixel clock 6.75 MHz, H total 444, V total 263** — a choice (`docs/HACKS.md`): 27/4 and 27/5
both fit the measured 15.2 kHz; 27/4 gives a 20.1 us horizontal blank (Psikyo's is 19.0 us),
27/5 gives 8.5 us. 57.805 Hz against MAME's 57.793 Hz (+207 ppm). 3552 clk a line.

### Interrupts

Level 4 autovectored at vblank, `irq4_line_hold` (802). Already what `maincpu.sv` does.

### Memory map

As HARDWARE_NOTES. Differences from the inherited decode: program ROM 2 MB (inherited 1 MB),
video registers end at 0x805FFF (inherited 0x807FFF), and C0000F-C00033 (OKI, bank, MCU) are new.

### Video

Two 16x16 4bpp tilemaps, 64x64 or 128x32, bank bit, row scroll; scroll offsets +32 Y on both
layers and +2 X on layer 1. 512 sprites of up to 8x8 tiles, tile number through `spritelut`,
6-bit colour, flips, no zoom or priority in MAME. Mixing: layer 0 (opaque), layer 1, sprites. No
flip in the driver.

Latency, from `screen.cpp` `vblank_begin` (the frame is drawn before `screen_vblank` runs): the
frame drawn at a vblank uses the tilemap state of that moment and the sprite copy taken at the
previous vblank. Sprites are one frame behind the tilemaps. Psikyo's driver builds a list from an
already-buffered copy, two generations; the inherited `spriteram_dbuf` + `sprite_line_list`
pipeline has one stage too many for this board.

When the games write (`docs/write_timing_mame.txt`, all seven sets, attract and play): the whole
4 KB sprite list in the first 16 lines after vblank start (17% in the first 2); scroll and
control in vblank; row-scroll RAM in vblank; tile VRAM and 25-50% of palette writes in some sets
across the visible frame.

### Sound

Two OKI M6295 at 1 MHz; 0x00000-0x2FFFF fixed, 0x30000-0x3FFFF banked over ROM 0x30000-0x6FFFF.
Mono. baryon/rolcrush/gaialast have one.

### Protection

68020 writes C00020, reads C00030 bits 31:24; the MCU latches port 1 on a port-2 bit-1 rising
edge, with port-2 bits 2/3 as "sent"/"received" flags cleared by the 68020's accesses. MAME runs
the MCU program; six of seven MCU ROMs are reconstructions shipped in MAME's sets.

### Per-game configuration

`.mra` mod byte: second OKI present (dreamwld, cutefght). Rotation from the `.mra`. DIPs per set.

## Component reuse map

| block | plan | source |
|---|---|---|
| 68EC020 | Keep | TG68K.C in `rtl/cpu/tg68k/` (Psikyo's vendoring, `PROVENANCE.md`) |
| main bus | Adapt | `rtl/cpu/maincpu.sv`: 2 MB ROM, OKI/MCU decode |
| M6295 x2 | Vendored | `rtl/sound/jt6295`: jotego jt6295 `7d76b0b` via Fuuki (GPL-3.0); same `hdl/*.v` in five sibling cores. Fuuki's `sample_cache.sv` is the model for serving its ROM deadline from SDRAM |
| 87C52 | Vendored | `rtl/mcu/jt8052`: JT8051 forked to an 8052 by Vamphalf/Eolith, from Eolith `717dbb7` (GPL-3.0) |
| tilemaps | Adapt | `tilemap_line_engine.sv` (Psikyo): offsets, 2 geometries |
| sprites | Adapt | `sprite_line_list.sv` / `sprite_line_engine.sv` (Psikyo): format, LUT, no zoom |
| compositor | Simplify | `compositor.sv`: fixed order, 0x400-entry sprite palette |
| video timing | Adapt | `video_timing.sv`: totals 444x263 done (`57e1837`); 308 active in Phase 2 |
| SDRAM | Keep, re-map | `rtl/memory/` (Psikyo); `sdram.sv` replaced by Seta's for its `dq_in` capture (Phase 1) |
| DDR3 ROM load, hiscore, CRT Adjust, rotation | Keep | from Psikyo |
| DIP/keys | Add | `rtl/mame_keys.sv` (skill asset) |

## On-chip RAM budget

From the `42baf8e` fit report: 386 of 553 M10K (70%), of which the framework (`sys/`, `ascal`)
and CRT Adjust take 52 + 43 + others outside `emu`. Largest core users:

| Block | M10K |
|---|---|
| work RAM, 128 KB | 128 |
| video registers, two 16 KB copies (`vreg_decode`) | 38 |
| sprite RAM double buffer (`spriteram_dbuf`) | 32 |
| palette, VRAM x2, sprite line buffer pair | 16 each |

DreamWorld adds the MCU ROM (8 KB, ~7 M10K), MCU RAM (256 B) and widens the sprite palette mirror
from 0x200 to 0x400 entries; the video registers end at 0x805FFF, which halves each copy. The one
to watch is work RAM: hiscore must keep sharing its port (Psikyo found a second read port doubles
it).

## Memory plan

SDRAM, 32 MB, at `clk_sys`. Proposed layout (the RTL's localparams become the source of truth):

| Region | Size | Client |
|---|---|---|
| maincpu | 2 MB | Port 2, narrow bridge |
| gfx1 sprites | 8 MB | Port 1, dedicated |
| gfx2 tiles | 2 MB | Port 0, both layers |
| spritelut | 256 KB | Port 2, narrow bridge |
| oki1, oki2 | 512 KB each | Port 2, freed clients c0/c4 (already promoted above the round robin) |

MCU ROM (8 KB) and RAM (256 B) in BRAM, the ROM loaded through ioctl. DDR3 only at load time.

**Sprite fetch budget** (`docs/sprite_load_mame.txt`): 3552 clk a line, about 3240 after the
line-buffer clear. Every set parks unused entries on visible lines but off-screen in X (up to 514
tile rows a line by Y alone), so the engine tests X before it fetches. With X tested the worst
real line is 113 tile rows, which leaves 28 clk a row for the LUT read plus the 8-byte gfx granule:
the two fetches have to overlap (a serial burst-4 read each is about 11 clk on its own port). The
cutefght zeroed list (512 visible rows of a blank tile) overruns any budget and draws nothing;
dropping its tail is invisible. At most 64 rows a line can change a pixel.

## Design decisions

**Follow MAME, including where MAME is wrong, and write down every place that is.** There is no
PCB here. MAME is the accuracy target and its acknowledged guesses are inherited deliberately. Each
goes in `docs/MAME_KLUDGES.md` when it is implemented, with what MAME does, what the hardware is
suspected to do, and what would settle it.

**Where a vendored module and MAME disagree, record it and keep the module.** It goes in
`docs/MAME_KLUDGES.md`, not into a "fix", until one side is shown to describe the chip.

**Every approximation of this core's own goes in `docs/HACKS.md`** in the commit it lands, with
what would make it correct.

**Transcribe the reference literally first, then look for the chip.**

**One `.rbf` for all games.** Per-set differences are `.mra` mod-byte configuration.

**Two Quartus revisions, `DreamWorld_stp` and `DreamWorld`,** differing only by a `DEBUG_ISSP`
macro. See [`WORKFLOW.md`](WORKFLOW.md).

**Licence: GPL-3.0-or-later.** jt6295 and jt8051 are GPL-3.0. `sys/` is never edited.

**Per-scanline rendering from buffered sprite RAM** — inherited from Psikyo, which tried a frame
buffer and went back. The snapshot point comes from the video-write sweep, not from MAME's vblank
copy alone.

**No multiplies, no divides, in 2D pipelines.**

**The inherited engines are adapted, not rewritten.** They are tested on hardware; each change is
made against a MAME-derived reference and the module's existing bench.

**Run the MCU, don't simulate its protocol.** MAME executes the 87C52 program; the core runs
jt8052 on the same ROM, so the reconstructed ROMs in the other six sets work unchanged.
`sim/mcu_tb` shows it producing MAME's whole 1737-byte stream.

**Stall the 68020 on the MCU handshake, as MAME does.** MAME spins the 68020 50 us after each
C00020 write and C00030 read (`to_prot_w`, `protdata_r`); the 68020 code does not poll. The core
holds the bus for the same time. The board's own mechanism is unknown: `docs/MAME_KLUDGES.md`.

**Sprite list: one generation, copied at vblank start, the copy atomic against the game.** The
copy has to finish before the game's first write of the new list, which can land in the first
two lines; holding a 68020 sprite-RAM access until the copy is done (about 2048 clk, 0.6 lines)
is the proposal for Phase 2.

## Pitfalls that already bind decisions here

| Entry | What it binds here |
|---|---|
| "Read both halves of a mechanism: the draw loop AND the pixel op" | dreamwld draws entries 0-511 with `transpen` into one bitmap: the last entry wins. A line buffer that runs out of time drops the highest entries. |
| "Sprite lists, line buffers and snapshots" | the sprite-RAM latch point and the inherited `spriteram_dbuf` copy timing |
| "Memory transport: req/valid contracts, latency, byte order" | OKI sample clients on Port 2, the spritelut redirect, the 2 MB CPU window |
| "MiSTer integration: reset, ioctl download, CONF_STR" | MCU ROM into BRAM during the download; OKI-count mod byte |
| "ROM loading: .mra, byte order, deployment" | `ROM_LOAD32_BYTE` program interleave, `ROM_LOAD16_BYTE` LUT |
| "When simulation passes and hardware fails" | the inherited benches that already fail, and the stale ones fixed in `e3ecde7` |

## Phased roadmap

**Phase 0 — Measurements and vendoring. The gate. Done.**

Exit criteria:

1. **Video-write sweep in play and attract**, 1800 frames, every set. — Met:
   `docs/write_timing_mame.txt`; four of the seven play runs ended on a demo or game-over screen
   (noted there).
2. **Sprite load per line from MAME captures.** — Met: `docs/sprite_load_mame.txt`; 113 tile rows
   with X tested, 28 clk a row at 54 MHz (Memory plan).
3. **The pixel clock.** — Met by decision: 6.75 MHz, `docs/HACKS.md`; no PCB measurement found.
4. **jt6295 and jt8051 vendored** with `PROVENANCE.md`. — Met, with a substitution: jt8051's
   upstream benches need jtframe `simunit.sh` and Ruby, not installed; `sim/mcu_tb` runs the real
   MCU ROM against MAME's stream instead (1737 of 1737 bytes). jt6295 had no benches in its copy;
   `sim/oki_tb` plays dreamwld phrases.
5. **MAME boot trace of dreamwld.** — Met: `docs/boot_trace_mame.txt`.
6. **Clock plan approved and the PLL regenerated.** — Met: `57e1837`, timing met (+5.123 ns).

**Phase 1 — CPU, memory map, MCU, SDRAM layout.**

2 MB ROM window, the new I/O decode (inputs, DSW, C00010/C00020/C00030, OKI and bank registers
as stubs), jt8052 with dreamwld.cpp's port model and the 50 us stalls, the MCU ROM download, the
new SDRAM map with Seta's `sdram.sv` (`dq_in` fix, see Open items), the `.mra` generator for all
seven sets. Exit: dreamwld and cutefght boot in simulation with a bus trace matching MAME's through
the protection handshake.

**Phase 2 — Video against a software model.**

`render_model.py` from dreamwld.cpp checked pixel-exact against MAME frames, then: video timing
308x224, tilemap offsets, the sprite format/LUT/wrap in the line engine, the compositor's fixed
order and 6-bit sprite colour. Exit: captured scenes of every set pixel-identical in simulation.

Steps, each measured with `sim/frame_tb` (captured state loaded through the CPU write ports,
two frames through `dreamworld_top` and the real SDRAM path) and `scripts/frame_compare.py`
against the model:

1. Model: done, 49 of 49 scenes identical to MAME.
2. Done. Timing: 308 active columns from screen x 0. Today 320, with hcnt 0 never given a tilemap
   pixel and columns 0 and 319 masked black (`dreamworld_core.sv` edge mask); `arcade_video`
   and `crt_chain` are sized 320 (`DreamWorld.sv`).
3. Done. Tilemaps: +32 Y on both layers, +2 X on layer 1, row-scroll index `((y + 32) & 0xff) >> 0|4`
   (`tilemap_line_engine.sv`). Geometry, cell decode, bank, transparency and the gfx byte order
   already match.
4. Done. Sprites: a linear walk of 512 records in place of Psikyo's display list; the dreamwld record
   (no zoom, 6-bit colour, no priority, X = ((x + 4) & 0x1ff) - 16); pen 0 always transparent
   (today it comes from Psikyo's control word at 0x401FFE); colour 6 bits through the line
   buffer and compositor; the copy at vblank, then the list built from it (today the list is
   built before the copy, a frame older than MAME's).
5. Done. Compositor: fixed order layer 0, layer 1, sprites; Psikyo's priority mask and backdrop
   logic removed; the sprite palette mirror widened to 0x000-0x3FF.
6. Done (`video_pipeline_tb` removed, superseded by `frame_tb`). The unit benches that assert Psikyo behaviour (`tilemap_rowscroll_tb`, `compositor_tb`,
   the sprite record benches, `video_timing_tb`) brought to dreamwld's.

**Phase 3 — Hardware bring-up and the standard features.**

`.mra` for all seven, inputs with the games' button names, DIPs (28-column lines), Pause, flip
screen through a fake DIP (the driver has none), CRT Adjust, hiscore, fast loading, HDMI
scaling/crop/rotation (baryon is ROT270). Exit: all seven boot and play on a DE10-nano, silent.

Inventory against the skill's standard (`video_audio_options.md`, `dips_inputs.md`, `hiscore.md`):
present from the Psikyo import -- DIP page from the `.mra`, Pause (J1 slot, CPU clock enable),
CRT Adjust (resized to 308), DDR3 loading, the HDMI rotator, aspect 4:3/3:4, audio mix menu,
`hiscore.v` (menu hidden until the `.mra` carries data). Missing or not to standard:

1. Flip: OSD "Flip 180" drives the HDMI rotator only and `flip_screen` is tied 0. To do: one
   core flip from the OSD or a fake `.mra` DIP (the driver has none), rotator flip 0, checked in
   `sim/frame_tb` against the unflipped model frame rotated 180.
2. OSD: Orientation without Auto (needs `game_rot` in the mod byte; baryon is ROT270); no
   Scale/Crop (`video_freak` not instantiated); HDMI-only options not hidden under direct video.
3. Inputs: `rtl/mame_keys.sv` not instantiated (MAME's keys alongside the pads); button names
   sourced only for dreamwld (the driver's comments) -- baryon inherits dreamwld's port, the
   other games' names need a source.
4. Hiscore: MAME's hiscore.dat has baryon, baryona and rolcrush; nothing for the other four.
5. README from the template; release revision build.
6. Hardware: every set boots, coins up and starts (coin/start through the remote API's keys),
   baryon rotated on HDMI, flip, pause, CRT Adjust, hiscore save/restore where there is data.

Results so far (stp `83b7924`, `scripts/play_test.py` and by hand, `debug/hw/play`, `bar`, `bara`,
`cf`, `flip`):
- All seven sets boot, take a coin and start from MAME's keys sent through the remote API
  (dreamwld to character select, cutefght to its character box, gaialast to plane select,
  rolcrush/rolcrusha to the mode menu, baryon/baryona to play). Baryon ignored one coin press
  in the scripted run and took two in a row by hand.
- Pause holds the frame and releases it in all seven.
- Flip: `sim/frame_tb` +FLIP on dreamwld-sw1500 and baryon-sw3600p, both frames identical to the
  model turned 180; on hardware three flipped dreamwld screenshots, turned 180, each identical to
  a MAME frame.
- Orientation Auto on baryona: the rotator's DDR3 framebuffer read back with `devmem` (paused)
  holds the picture rotated, its text reading left to right. MiSTer screenshots cannot show this:
  they read the scaler's input buffer, the unrotated raster (Main_MiSTer `scaler.cpp`).
- Hiscore: the `.mra` carries the data for baryon, baryona, rolcrush; no `.nvm` is written until
  a new score is set (`hiscore.v` saves only a changed table), so save and restore are not yet
  exercised.
- Not yet checked on the board: CRT Adjust at 308 columns, Scale and Crop, the menu under direct
  video, the fake Flip DIP (the same XOR as the OSD option).
- Release revision `f356a8e` (+5.049 ns, 385 of 553 M10K): dreamwld and baryon boot, Pause holds;
  dreamwld starts from the scripted coin and Start. Baryon again missed the single scripted coin
  press, as in the stp run, and took two presses by hand there; a check with a controller is open.

**Phase 4 — Sound.**

Two jt6295 with bank registers on Port 2 clients, mono mix, the oki2 mod byte. Exit: OKI command
traces from MAME reproduce correct audio, by ear and against a MAME capture.

Steps:
1. The chips: two jt6295 in `dreamworld_core` (1 MHz enable, 1 in 54; pin 7 low, as
   `OKIM6295(..., PIN7_LOW)`), written and read at 0xC00018 / 0xC00028, banks at 0xC0000F /
   0xC0002F; the second held in reset and silent where the mod byte has no oki2 (baryon,
   rolcrush, gaialast).
2. ROM path: Fuuki's `oki_rom_bridge` (one held fetch, the byte kept for the chip's re-reads)
   and `sample_cache` (granules per channel with next-granule prefetch: jt6295 does not wait for
   a miss), one each on Port 2's spare priority clients c0 and c4. The address is the chip's
   below 0x30000, and the bank's 64 KB of the 512 KB ROM above (`oki1_map`, `machine_start`).
3. Mix: MAME scales a full-volume voice to full scale and sums both chips into one mono speaker
   at 1.0; the 16-bit output is the two chips' 14-bit sums times 16, clamped, on both channels.
4. Reference: a MAME trace of every OKI and bank write with its time, attract and play, and a
   Python transcription of `okim6295.cpp`/`okiadpcm.cpp` producing each chip's samples; a bench
   replays the trace through the core's write ports and compares the jt6295 outputs.
5. Hardware: every set by ear.

Results so far: stp `36dff44` (+5.130 ns, 402 of 553 M10K) deployed; by ear on the board, Dream
World (the coin, play) and Baryon sound right. On the same run Dream World in play showed a
sprite priority problem and flickering lines (reported by the user, not yet captured). The
captured dreamwld play scenes peak at 52 sprite tile rows on a line; the engine fetches each
row's spritelut word on Port 2 (shared with the 68020 and, ahead of it, the two OKI caches),
then its gfx granule, then writes 16 pixels, all in series, and a line cut off by line_start
drops its last, topmost sprites. `sim/frame_tb` runs with the 68020 paused, so it has no Port 2
contention.

Measured on the board with the overlay counters (`debug/hw/ovr`): stp `36dff44` cut 126,033
sprite lines in the ~25 s after coin-up (86 a frame, worst line 3,298 clk); MAME's captures put up
to 76 tile rows on a line at coin+150. `121f144` overlaps each row's fetch with drawing (a 2-row
queue): `sim/frame_tb` on that scene with a random Port 2 read every 16 clk, no line cut, worst
3,028 of 3,244 clk, identical to the model; on the board, no line cut from coin-up through 3,195
frames. 1,568 lines are cut in the first 1,247 frames after launch, probably the boot frames with
sprite RAM still zero (512 sprites at the top left; not checked). The user, playing Dream World
on `121f144`: the flickering lines and the sprite priority problem after coin-up are gone.

**Phase 5 — Accuracy and the rest.** `docs/MAME_KLUDGES.md` (sprite priority/zoom unknowns,
C00010 MCU reset) and `docs/HACKS.md` current; floorplan; release.

Steps:
1. Accuracy: whether the game runs at MAME's pace on the board (the 68020 is slower than MAME's
   model in the handshake loop), from attract and play screenshots matched to MAME frames.
2. Docs current: HACKS, MAME_KLUDGES, STATE, LESSONS_LEARNED, README; `THIRD-PARTY.md` with
   every vendored component, its licence and its PROVENANCE.
3. Release revision built at the final commit, timing closed; `scripts/floorplan.json` and the
   floorplan in `docs/floorplan/`.
4. Smoke test: every parent set boots, coins up and starts on the release build, and its attract
   screenshot matches a MAME frame.
5. Release files staged locally (`releases/Arcade-DreamWorld_<date>.rbf`, the `.mra` set out of
   `_dev`), validated; publishing (squash onto master, push, the Downloader database) waits for
   the user.

Results so far: release revision `27e1ee0` (default seed, every clock met, worst `clk_sys` setup
+4.873 ns, 397 of 553 M10K), deployed as `DreamWorld_30000011.rbf`. `scripts/play_test.py`, all
seven sets: each boots, Pause holds the frame and releases it; coin and Start took on six, and on
rolcrusha at the second run (a missed scripted coin, as Baryon's in Phase 3). Attract screenshots
25 s after launch (`debug/hw/smoke/`, `scripts/hw_vs_mame.py` against MAME frames 300-3000):
dreamwld, cutefght and gaialast identical to MAME frames 1385, 1399 and 1394. baryon (native
orientation, frame 1380) and rolcrush (frame 1372) match in the tilemaps and HUD, but the
demo's moving objects are elsewhere: the ships, asteroids and shots in baryon, the launcher angle
and ball chain in rolcrush. Why is not known: the demo's state diverges from MAME's before 25 s.

Staged on `develop`: `releases/Arcade-DreamWorld_20261017.rbf` (the `27e1ee0` build, the bitstream
tested above) and the seven `.mra` files in `releases/` and `releases/_alternatives/`, unchanged from
the tested `_dev` set, `validate_mra.py` clean. The demo difference is a known issue in the README.
Squash onto `master`, push and the Downloader database wait for the user.

**Phase 6 — Savestates, state dumps and cheats.** Optional. The inherited RTL was not written for
state capture; `docs/STATE.md` starts in Phase 1 for every RAM added.

## Verification strategy

- **MAME is a reference generator, driven from scripts.** Boot traces, VRAM/register/palette dumps
  at known frames, OKI command logs. MAME 0.289 matches the driver source.
- **The software model comes before the RTL.**
- **Every vendored module is verified against MAME before it is wired to anything.**
- **`.mra` files are generated, not written**, checked by `validate_mra.py`.
- **Worst cases are measured in the RTL** (the inherited `sp_render_max` / overrun counters).

## Repository setup

Seeded from **MiSTer-devel/Template_MiSTer** (`5de192e`), then Arcade-Psikyo_MiSTer's RTL and
benches imported (`de225e3`). Quartus **17.0.2**.

## Open items

**The 68020 runs the handshake loop at about half MAME's speed** (bench numbers above), so the
game reaches its vblank handler about 0.8 s later than in MAME. It keeps MAME's pace after that:
the twelve dreamwld attract screenshots of `faf5c60`, which include the gameplay demo, matched
MAME frames 654 to 4164 over 21:52:00-21:53:00 by the MiSTer's own timestamps, 3,510 frames in
60 s against 3,468 at 57.805 Hz (the timestamps are whole seconds, so +-2 s). A busier scene in a
real game could still overrun a frame; not measured.

**SDRAM_CLK phase is not swept.** 301.5 degrees is estimated from two overlay captures
(`rtl/pll/pll_0002.v`); a read-margin sweep at several phases would replace the estimate.

**Tile VRAM and palette are written across the visible frame.** MAME applies them at the next
vblank draw; the inherited engines read them live. Seen on hardware: a palette fade step
(633 entries) drew the top 28 lines of a frame in the previous step's colours (s04 above). The
sweep has a third of dreamwld's play-mode palette writes outside vblank in MAME's own timing,
so a faster CPU narrows this but does not remove it. Options: queue the writes and apply them
at vblank start (a CPU-side copy for reads, a display-side copy updated from the queue, sprites
one more generation back; the display then equals MAME's frame, a frame later), or leave the
live read. Decided: live reads stay (`docs/HACKS.md`, `docs/MAME_KLUDGES.md`).

**Bugs inherited from Psikyo.** `dreamworld_core.sv` records a one-tile X offset in both tilemap
layers on Psikyo hardware, unresolved there; `video_pipeline_tb` and `video_timing_tb` fail on
the imported modules. Each is checked against DreamWorld's own reference in Phase 2.

**Forward references in the Psikyo RTL.** `effective_pause` (into `maincpu.pause`) and
`core_reset` (into the OPL4) were used before their declarations; ModelSim rejects both
(vlog-2388). Fixed here for `effective_pause`. Whether Quartus bound Psikyo's ports to implicit
1-bit nets instead is unverified; worth checking in the Psikyo core.

**Stale comments.** Unchanged modules still name removed files (`sdram_arbiter5`,
`sprite_render_engine`, `ddram_arbiter`). Swept as each module is touched.

## Next steps

1. Phase 1: Seta's `sdram.sv`, the SDRAM layout and `.mra` generator, the 2 MB ROM window and I/O
   decode, jt8052 wired with the stalls, then dreamwld booting in simulation against
   `docs/boot_trace_mame.txt`.
