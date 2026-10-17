# MAME kludges this core reproduces

This project follows MAME, including where MAME is wrong (ROADMAP, "Design decisions"), so the
software model and the RTL reproduce MAME's guesses on purpose. This file lists each one that
touches an in-scope set: where it is in MAME, what the core does, and what would settle the real
behaviour.

It also records where a vendored, silicon-derived module disagrees with MAME and the module was
kept (ROADMAP, "Where a vendored module and MAME disagree").

This core's own approximations are not here; they are in `HACKS.md`.

Source references are to `src/mame/misc/dreamwld.cpp` unless named. MAME 0.289 (the checkout's
only change to the driver since `mame0289` is the `SCREEN()` constructor).

**Core column:** *copies* MAME; *differs* (and why); *n/a* (not in the core's scope);
*not checked*.

Every set is `MACHINE_SUPPORTS_SAVE` only: no imperfect flags.

## Protection

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| 50 us wait after each MCU handshake access | `to_prot_w` and `protdata_r` (781-794): `spin_until_time(50 us)`, "give it time to respond" | copies: `maincpu.sv` holds the bus `STALL_CLKS` (2700 at 54 MHz) after a write to 0xC00020 and a read of 0xC00030 | How the board makes the 68020 wait (a PCB trace of the handshake), or that it does not |
| The handshake flip-flops | `prot_p2_w` / `prot_p2_r` / `to_prot_w` / `protdata_r` (736-794): port-2 bits 2 and 3 are the MCU's own latch, cleared by the 68020's accesses and restored by the MCU's next P2 write; the 68020's C00020 data is not passed on | copies, `rtl/mcu/semicom_mcu.sv` | The board's handshake logic (PCB trace) |
| 0xC00010 "might reset the MCU?" | map line 434: not mapped | copies (write ignored) | — |
| Six of seven MCU ROMs reconstructed | ROM_START: `BAD_DUMP`, "handcrafted from Dream World MCU" | copies (the core runs the ROM MAME ships) | Dumps of those MCUs |

## Video

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| No sprite priority, no sprite zoom | header (89-95): "we don't support it here", unknown whether the clone hardware has them | copies: no priority, the zoom path fed 0 (`sprite_record_decode.sv`) | A PCB capture of a scene MAME draws differently |
| The whole frame drawn at vblank from the state at that instant | `screen_update` runs at vblank start (`screen_device::vblank_begin`); palette, VRAM and scroll written during the visible frame apply to all of it | differs: the core draws each line from the palette, VRAM and scroll as they stand when the line is drawn, as a raster board does (the sprites keep MAME's vblank copy). A write that lands while the frame is drawn shows from that line down; `HACKS.md` | A PCB capture of a palette fade or a mid-frame VRAM write |

## Vendored modules that disagree with MAME

| Module | MAME says | The module does | Kept because | Would settle it |
|---|---|---|---|---|
| jt6295 (`rtl/sound/jt6295`) | `okim6295::write`: a start for a voice that is playing is ignored ("fixes Got-cha and Steel Force") | restarts the voice with the new address and attenuation | -- not kept: `dreamworld_sound.sv` masks busy voices out of the second byte, as MAME. dreamwld fades phrase 51 in by re-sending its start every 13.7 ms with less attenuation (`debug/oki_trace/dreamwld_play`), so jt6295 restarted it each time, louder. The games MAME cites behave on the board as MAME's rule | -- |
| jt6295 (`rtl/sound/jt6295`) | a start takes effect at the next sample after the write (`okim6295::write` updates the stream first) | starts the voice at its next internal channel slot, so a voice can begin one sample (165 us) later relative to the voices already playing | the decode is exact: `sim/oki_phrase_tb` 20 of 20 phrases sample-identical; `sim/oki_trace_tb` (3 s of dreamwld play, busy-voice masking in): identical for the first 12,065 samples, then each later start one sample later than the model, the following 1,158 samples identical once the model is shifted to match | a recording of the chip's start latency |
| TG68K.C (`rtl/cpu/tg68k`) | The 68EC020's `CLR` writes without reading (MAME's m68020 makes no read) | reads the operand first, as a 68000 does: `CLR.L (A0)+` at 0x10E reads each long of VRAM before clearing it (sim/boot_tb trace, 18,436 extra reads in the first 50 ms) | No read in this map has a side effect except 0xC00030 (the MCU latch acknowledge), which the games only read with a byte read; every write still matches MAME (34,223 of 34,223) | A `CLR` aimed at 0xC00030 in any set's program would show it; a scan of the ROMs for one |

