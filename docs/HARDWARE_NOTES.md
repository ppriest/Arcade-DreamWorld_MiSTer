# DreamWorld: hardware notes

The SemiCom 68EC020 board, as MAME models it. Each fact cites its source.

Source: MAME `src/mame/misc/dreamwld.cpp` (line numbers below), checkout at `mame0289-1510`; the
only change to the driver since the `mame0289` tag is the `SCREEN()` constructor (API only), so
MAME 0.289 (`mame.exe -version`) is the matching binary. `-listxml` from that binary. Everything
here is MAME's model unless marked otherwise.

The driver's header calls the board "a copy of Psikyo's 68020 based hardware" with "various subtle
changes" (lines 17-24). That is why this core starts from Arcade-Psikyo_MiSTer.

## Sets

All seven are `MACHINE_SUPPORTS_SAVE`, driver status `good` (lines 1269-1275). Bytes are loaded
bytes from `-listxml`.

| Set | Parent | Game | Rot | Config | maincpu | gfx1 (sprites) | gfx2 (tiles) | oki1 | oki2 |
|---|---|---|---|---|---|---|---|---|---|
| baryon | - | Baryon - Future Assault (set 1) | 270 | baryon | 1 MB | 4 MB | 2 MB | 512 KB | - |
| baryona | baryon | Baryon (set 2) | 270 | baryon | 1 MB | 4 MB | 2 MB | 512 KB | - |
| cutefght | - | Cute Fighter | 0 | dreamwld | 2 MB | 8 MB | 2 MB | 512 KB | 512 KB |
| rolcrush | - | Rolling Crush (1.07.E) | 0 | baryon | 1 MB | 2 MB | 2 MB | 512 KB | empty |
| rolcrusha | rolcrush | Rolling Crush (1.03.E) | 0 | baryon | 1 MB | 2 MB | 2 MB | 512 KB | empty |
| gaialast | - | Gaia - The Last Choice of Earth | 0 | baryon | 1 MB | 6 MB | 2 MB | 512 KB | empty |
| dreamwld | - | Dream World | 0 | dreamwld | 1 MB | 2 MB | 2 MB | 512 KB | 512 KB |

Every set also has `mcu` (8 KB), `spritelut` (256 KB, 16-bit, `ROM_LOAD16_BYTE`) and `unknown`
(64 KB, CRC `0da8db45` in all seven, not referenced by the driver). Largest set: cutefght,
0xD52000 bytes (13.3 MB).

Only dreamwld's MCU ROM is a real dump (`87c51rap.bin`, chip marked P87C52EBPN, die 87C51RA+,
line 1162). The other six are `BAD_DUMP`, "handcrafted from Dream World MCU using correct
protection data for this game" (lines 889, 917, 984, 1060, 1091, 1242).

baryon and baryona share every region except `maincpu`. rolcrush and rolcrusha share `oki1` and
the `unknown` ROM only.

## CPUs and chips

| Tag | Part | Clock | Role | Existing RTL |
|---|---|---|---|---|
| maincpu | 68EC020 | 32 MHz / 2 = 16 MHz, "verified" (800) | main CPU | TG68K.C, already in this core (from Psikyo) |
| mcu | AT89C52 in MAME; 87C52 / AT89C52 / 8752 on the PCBs | 32 MHz / 2 (804, "unknown clock (value from docs)"); PCB notes say 16 MHz (970, 1150) | protection | jt8051, vendored in Arcade-Eolith/Vamphalf (`rtl/qs1000/jt8051`) and jtcores `modules/jt8051` |
| oki1 | OKI M6295 (AD-65) | 32 MHz / 32 = 1 MHz, pin 7 low, "verified" (826) | sound | jt6295, vendored in Eolith, Fuuki, GStream, NixPirates, Vamphalf; jtcores `modules/jt6295` |
| oki2 | OKI M6295 | 1 MHz, pin 7 low (838) | sound, dreamwld config only | as above |
| video | Actel A1020B / A40MX04 FPGAs on the PCB (layouts, 853-872) | - | 2 tilemaps + sprites | the Psikyo core's engines, to be adapted |

No sound CPU: the 68020 drives the OKIs directly.

## Clocks

| Clock | Source |
|---|---|
| 32 MHz XTAL | PCB layouts (856, 948, 1020, 1126); CPU /2, OKI /32, MCU /2 |
| 27 MHz XTAL | PCB layouts (861, 952, 1025, 1131); not used in the driver |
| VSync 57.793 Hz | `set_refresh_hz(57.793)` (813); rolcrush notes "V-SYNC @57.793 Hz" (1047) |
| HSync 15.19-15.27 kHz | rolcrush notes, "(floating)" (1048); dreamwld notes 15.2 kHz (1151) |
| vblank 2500 us | `set_vblank_time` (814) |

**The pixel clock is unknown.** MAME sets no raw timing (`set_size(512,256)`, visible
308x224, lines 815-816). Two divisions of the 27 MHz crystal fit the measured rates:

| Pixel clock | H total (at 15.20 kHz) | V total (at 57.793 Hz) | Frame rate | Line active / blank |
|---|---|---|---|---|
| 27 MHz / 4 = 6.75 MHz | 444 | 263 | 57.805 Hz | 45.6 us / 20.1 us |
| 27 MHz / 5 = 5.4 MHz | 355 | 263 | 57.838 Hz | 57.0 us / 8.7 us |

Neither is confirmed. The 5.4 MHz case leaves an 8.7 us horizontal blank, short for a 15 kHz
monitor; that is an argument, not a measurement. Closing it needs a PCB measurement (pixel clock
or H total), footage with a known capture clock, or the video FPGA's divider.

## Video

From `screen_update` and `draw_sprites` (lines 203-393):

- **Screen**: 308x224 visible, 57.793 Hz. Aspect 4:3; baryon/baryona are ROT270.
- **Palette**: 4096 entries, xRGB_555, at 0x600000 (`PALETTE ... xRGB_555, 0x1000`, 821; map
  422). Sprites use 0x000-0x3FF (64 colours of 16, `gfx1` colour base 0x000, 0x40 colours, 700);
  tiles 0x800 + (layer*0x40 + colour)*16, i.e. layer 0 at 0x800-0x87F and layer 1 at
  0xC00-0xC7F (`gfx2` colour base 0x800, 701; tile info 283).
- **Tilemaps**: two layers of 16x16 4bpp tiles (`gfx_16x16x4_packed_msb`, 701), 64x64 or 128x32
  tiles (289-292). Tile word: code bits 12:0, colour bits 15:13 (282-283); code gets
  `bank << 13`.
  - Layer control word, `vregs[0x10/4]` / `vregs[0x14/4]` (330): bit 6 bank (334), bit 10 size
    (344), bits 9:8 row scroll on, bit 9 one entry per 16-line tile row (350-352).
  - Scroll: `scrolly = vregs[0] + 32`, `scrollx = vregs[1]` for layer 0; `vregs[2] + 32`,
    `vregs[3] + 2` for layer 1 (328-329).
  - Row scroll: `lineram[layer*0x100 + (((line + 32) & 0xFF) >> tile_rowscroll)]` added to the
    X scroll of tilemap row `(line + scrolly) & row_mask` (361-369).
  - Layer 0 is opaque; layer 1 has pen 0 transparent (293-294). No enable bit, no transparent-pen
    select (the driver header, 20-23).
  - Same register offsets as Psikyo (`psikyo_v.cpp` reads `vregs[0x402/4]` etc. from 0x804000;
    dreamwld's share starts at 0x804400). Psikyo's tilemap modes 0 and 1 are exactly these two
    sizes (`tilemap_addrgen.sv`).
- **Sprites**: the first 0x1000 bytes of sprite RAM, 512 entries of two longs (207), drawn in
  order, later entries on top, pen 0 transparent (249):
  - long 0: X bits 8:0, X size bits 11:9, Y bits 24:16, Y size bits 27:25 (size+1 tiles, up to
    8x8)
  - long 1: tile bits 16:0, colour bits 29:24, X flip bit 30, Y flip bit 31
  - X += 4 then -16, wrapped to 9 bits (209, 226-227, 243); each tile is also drawn at -0x200 in X
    and Y (250-252), i.e. positions wrap at 512
  - each tile number goes through the `spritelut` ROM (`redirect[tileno]`, 208, 249) and
    increments across the block (254)
  - no zoom and no sprite/tilemap priority in MAME; the driver says it does not know whether the
    board has them (89-95)
- **Sprite buffering**: on the rising edge of vblank, `spritebuf[1] = spritebuf[0]` then
  `spritebuf[0] = spriteram` (313-321); drawing reads `spritebuf[0]`, so sprites are one frame
  behind the CPU's writes. `spritebuf[1]` is never drawn.
- **Mixing**: layer 0, layer 1, sprites, in that order (387-390). No backdrop: layer 0 is opaque.
- **Flip**: the driver has no flip screen.

## Memory map

68EC020, `baryon_map` (417-439) plus `dreamwld_map` (441-447):

| Address | What | Line |
|---|---|---|
| 000000-1FFFFF | program ROM (1 MB or 2 MB loaded) | 419 |
| 400000-401FFF | sprite RAM (8 KB; sprites read the first 4 KB) | 421 |
| 600000-601FFF | palette RAM | 422 |
| 800000-801FFF | layer 0 VRAM | 423 |
| 802000-803FFF | layer 1 VRAM | 424 |
| 804000-8043FF | row-scroll RAM | 425 |
| 804400-805FFF | video registers (and RAM) | 426 |
| C00000-C00003 | inputs (32-bit) | 428 |
| C00004-C00007 | DSW (16-bit, same value on both words) | 429 |
| C0000F | oki1 bank (write, bits 1:0) | 431 |
| C00018 | oki1 | 432 |
| C00020-C00023 | write to MCU | 435 |
| C00028 | oki2 (dreamwld config) | 446 |
| C0002F | oki2 bank (dreamwld config) | 445 |
| C00030-C00033 | read MCU latch (bits 31:24) | 436 |
| FE0000-FFFFFF | work RAM, 128 KB | 438 |

Interrupt: level 4 at vblank, `irq4_line_hold` (802).

## Sound

Each OKI addresses 256 KB: 0x00000-0x2FFFF fixed, 0x30000-0x3FFFF a 64 KB bank (398-408). The
bank register selects one of four 64 KB windows starting at ROM offset 0x30000 (`data & 3`,
413; 709-716), so ROM 0x30000-0x6FFFF is reachable and 0x70000-0x7FFFF is not. One mono speaker,
both chips at gain 1.0 (824-840).

## Protection

The MCU's port 1 is a data output, port 2 a handshake (736-794):

- 68020 write to C00020: clears port-2 bit 2 ("data sent"); MAME then spins the 68020 50 us.
  The data written is not passed to the MCU (781-786).
- MCU raises port-2 bit 1: port 1 is latched (756-759).
- 68020 read of C00030: clears port-2 bit 3, spins 50 us, returns the latch in bits 31:24
  (788-794). The game stores this "protection data (irq code)" at FFD000 (436).
- The MCU reads back port 2 (`prot_p2_r`, 771-779).

The dumped MCU program is 0x3A bytes plus a data table (97-102). C00010 "might reset the MCU"
(434), not modelled.

## Inputs

32-bit port at C00000 (`INPUT_PORTS_START( dreamwld )`, 451-470), all active low: COIN1 bit 0,
COIN2 bit 1, START2 16, P2 B3/B2/B1 17-19, P2 LEFT/RIGHT/DOWN/UP 20-23, START1 24, P1 B3/B2/B1
25-27, P1 LEFT/RIGHT/DOWN/UP 28-31. Button names from the driver comments: Dig, Jump, Book
(dreamwld, 456-466). The DSW layout differs per set (dreamwld 472-499, baryon 503-513, rolcrush
538-570, cutefght 596-631, gaialast 657-696).

## Feasibility

Not a large board: a 16 MHz 68EC020 already running in the Psikyo core, two OKIs and an 8051
with RTL in sibling cores, 13.3 MB of ROM against a 32 MB SDRAM module. No feasibility study.
