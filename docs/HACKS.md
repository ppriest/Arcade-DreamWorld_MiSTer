# Hacks, approximations and workarounds in this core

Everything in this core's own RTL, scripts or `.mra` layout that is known not to be what the
hardware does: a stand-in, a shortcut, a value chosen to make something work, a workaround for a
tool. Each entry is added in the commit that introduces the hack and removed in the commit that
removes it.

This is not `MAME_KLUDGES.md`. That file lists MAME's own guesses that the core reproduces on
purpose because MAME is the reference. This file lists what is ours.

Rules:

- An entry cites `file:line` (or a module and signal name if the line moves often), and the
  evidence column says what was measured, or "unverified".
- "What would make it correct" names the work, not "fix later".
- A hack whose entry is missing is a bug. A hack whose entry is stale is worse: update it in the
  same commit as the code.
- Severity is what a player or a verifier would see: **visible** (wrong pixels, wrong sound, wrong
  timing a game can hit), **latent** (wrong only for input no in-scope set produces), **tooling**
  (affects the build or the bench, not the bitstream).

| What | Where | Why it is a hack | What would make it correct | Evidence | Severity |
|---|---|---|---|---|---|
| Pixel clock 6.75 MHz (27 MHz / 4), H total 444, V total 263 | `rtl/video/video_timing.sv` `H_TOTAL`/`V_TOTAL`; `DreamWorld.sv` `ce_pix` | MAME sets no raw timing (`set_size(512,256)`, 57.793 Hz). 27/4 and 27/5 both fit the measured 15.2 kHz; 27/4 chosen for its 20.1 us horizontal blank (Psikyo, the board this copies, has 19.0 us), against 8.5 us for 27/5 | A PCB measurement of the pixel clock, H total or V total | 57.805 Hz against MAME's 57.793 Hz (+207 ppm), 15.203 kHz; unverified | visible |
| Sync pulse widths and positions | `rtl/video/video_timing.sv` `H_SYNC_*`, `V_SYNC_*` | 32-pixel hsync from hcnt 331 (22 pixels after the 308 visible columns, which keeps them where the middle 308 of the earlier 320-wide window were), 3-line vsync 4 lines into vblank: chosen, MAME has none | A PCB measurement of the sync timing | unverified | visible (analog only) |
| 68020 sprite RAM writes held during the vblank copy | `rtl/cpu/maincpu.sv` `spr_hold`; `rtl/video/spriteram_dbuf.sv` | MAME's `screen_vblank` copy takes no time; this one takes 2048 clk (0.6 lines), and the game writes the next list from the first lines after vblank start (`docs/write_timing_mame.txt`), so a write waits for the copy rather than landing half in the old frame | Nothing on the board is known; MAME's behaviour is matched as long as the hold never changes what the game does | `sim/frame_tb` loads its state with the CPU paused, so the hold is not exercised there | latent |
| Palette, tile VRAM and scroll read live, not latched at vblank as MAME's draw is | `rtl/dreamworld_core.sv` (`u_palette`, `u_palette_snap`, `u_vram0`, `u_vram1`), `rtl/video/vreg_decode.sv` | Kept by decision: queuing the writes to vblank would match MAME's frame exactly, at a CPU-side and a display-side copy of each RAM and a frame of latency. A write that lands while a frame is drawn shows from that line down; MAME shows it for the whole frame | Queue the writes and apply them at vblank start, sprites one generation further back (ROADMAP, Open items) | dreamwld attract on hardware: a 633-entry palette fade step drew rows 0-27 of one frame in the previous step's colours (`debug/hw/p2/s04_vs_mame.png`); the other 11 screenshots match MAME exactly. The core's 68020 runs at about half MAME's speed, which pushes such writes further into the frame | visible (a few lines at fades) |
| SDRAM_CLK at 301.5 degrees, 54 MHz | `rtl/pll/pll_0002.v` `phase_shift1` | Estimated from two overlay captures: 180 samples on the beat 0/1 boundary, 0 reads 0000 | A phase sweep on hardware: read margin at several shifts, as Seta's `sdram_check.py` | two overlay captures | visible if wrong |

<!-- Examples of the shape, from sibling cores:
| Sound mailbox is a stub that answers the power-on test | `rtl/gx_snd_stub.sv` | No sound CPU yet; the stub returns the reply the test expects and a heartbeat | Phase 3: the real sound board | The game's RAM check passes with it; nothing else is exercised | visible |
| Sound-command spin of 800 CPU clocks after a latch write | `rtl/cpu/…_bus.sv:NNN` | Copies MAME's 40 us wait; the real board's mechanism is unknown | A measurement of the latch on hardware | Without it the second byte overwrote the first (commit) | latent |
| Sound CPU reset held 1,024 clocks | `rtl/….sv:NNN` | MAME's pulse is zero-length; the T80 needs to see it | The measured reset length | A PCB measurement says about one second | latent |
| Screen timing from one game used for every game | `rtl/video/…crtc.sv` | MAME declares 60 Hz with no comment; the one PCB-verified rate is used for all | Per-game timing from PCB measurement | 0.043% from the verified rate | visible |
-->

## Removed

Entries move here when the hack is gone, with the commit that removed it, so a later reader can
tell "never had it" from "had it and fixed it". Delete a row once nothing else refers to it.

| What | Removed by | Replaced with |
|---|---|---|
| OKI M6295 stand-ins (status 0xF0, commands dropped) | the Phase 4 sound commit | `rtl/sound/dreamworld_sound.sv`: two jt6295 with their banks, ROMs through `sample_cache` on Port 2 |
