# DreamWorld state inventory

What a savestate or a state dump has to carry, kept current as RTL lands (the skill's
`savestates.md`). "Skip" needs a reason: a ROM table from the `.mra`, or something re-derived
every frame. The inherited Psikyo RTL was not written for state capture; borrowable ports are
noted where they exist.

## RAMs

| Region | RTL | Width x depth | Bytes | Save? |
|---|---|---|---|---|
| Work RAM 0xFE0000 | `dreamworld_core` `u_workram` | 16 x 65536 | 128 KB | yes (port A shared with hiscore, CPU paused) |
| Sprite RAM 0x400000, CPU side | `spriteram_dbuf` | 16 x 4096 | 8 KB | yes |
| Sprite RAM snapshot (the copy drawn from) | `spriteram_dbuf` `u_snap` | 16 x 2048 | 4 KB | yes, or re-copy at the restore point |
| Palette 0x600000 | `dreamworld_core` `u_palette` | 16 x 4096 | 8 KB | yes |
| Sprite palette mirror | `dreamworld_core` `u_palette_snap` | 16 x 1024 | 2 KB | rebuild from the palette |
| Tile VRAM 0x800000 / 0x802000 | `u_vram0`, `u_vram1` | 16 x 4096 each | 16 KB | yes |
| Row-scroll RAM and vregs 0x804000 | `vreg_decode` `u_ram_l0` / `u_ram_l1` (two copies) | 16 x 8192 each | 32 KB | one copy; the other rebuilt |
| Sprite line buffers | `sprite_line_buffer` | per line | - | skip: rebuilt within two lines |
| MCU internal RAM | `semicom_mcu` `ram` | 8 x 256 | 256 B | yes |
| MCU ROM | `semicom_mcu` `rom` | 16 x 4096 | 8 KB | skip: from the `.mra` |

## Registers and FSMs

| What | RTL | Bits | Save? | MAME `save_item` equivalent |
|---|---|---|---|---|
| Handshake port 2, latch | `semicom_mcu` `port2`, `latch` | 16 | yes | `m_port2_data`, `m_protlatch` |
| P1 latch | jt8052 `p1_o` (SFR) | 8 | yes, with the MCU | `m_port1_data` |
| Layer scroll and control | `vreg_decode` latched registers | 6 x 16 | rebuild from the vregs RAM | `m_vregs` |
| OKI bank registers | `dreamworld_sound` `oki1_bank`, `oki2_bank` | 2 x 2 | yes | `m_okibank` entries |
| OKI command byte pending | `dreamworld_sound` `oki1_pend`, `oki2_pend` | 2 | yes, with the chips | `m_command` |
| CPU handshake stall | `maincpu` `stall_run`, `stall_cnt` | 13 | restore idle (save at an instruction boundary) | - |

## Chip state

| Chip | Module | Addressable? | Tier | Note |
|---|---|---|---|---|
| 68EC020 | TG68K.C kernel | no | self-dump stub, as planned in the Psikyo core's `docs/savestates.md` | |
| 87C52 | jt8052 | registers in `jt8052_regs` and SFRs; no state port | to be added | the program is a 0x3A-byte loop; saving at its wait loop needs PC, DPTR, A, P1, P2 |
| M6295 x2 | jt6295 (`dreamworld_sound`) | no: channel state circulates in `jt6295_serial`'s shift registers | to be added | per voice: address, stop, attenuation, ADPCM signal and step; MAME saves `m_voice[]`, `m_command` |

## Deliberately skipped

| What | Why it need not be saved |
|---|---|
| MCU ROM | loaded from the `.mra` |
| Sprite line buffers, tilemap prefetch, sprite row queue | re-derived within two lines of the restore point |
| OKI sample caches | refilled from SDRAM on the next fetch |

## Frame alignment

Restore point `frame_start`. The sprite snapshot is one generation, copied at vblank start
(`frame_start`) and drawn the frame after; it must be saved with the live sprite RAM.
