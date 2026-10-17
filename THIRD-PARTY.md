# Third-party code and licences

**This project is GPL-3.0-or-later.** `LICENSE` carries the GPLv3 text. jt6295, jt8052, the SDRAM
controller, CRT Adjust and `hiscore.v` are GPL-3.0-or-later, so the whole is GPL-3; code can come in
from GPL-2-or-later MiSTer cores, not go back out (Arcade-KonamiGX_MiSTer's `THIRD-PARTY.md`, "Why
GPL-3, and why it is one-way").

Each vendored directory's `PROVENANCE.md` names the source and every local change. This file records
what each dependency obliges.

## Dependencies

### Arcade-Psikyo_MiSTer — GPL-3.0-or-later

The core started as a copy of it: the tilemap and sprite line engines (`rtl/video/`), the CPU bus
glue (`rtl/cpu/maincpu.sv`), the memory modules (`rtl/memory/`), the debug probes (`rtl/debug/`) and
the scripts. Same author and licence as this project. Obligations: publish the source.

### TG68K.C — LGPL-3.0-or-later

<https://github.com/TobiFlex/TG68K.C> at `ade33e396a1e647c2de9daf71ff9d5b3979639b2`:
`rtl/cpu/tg68k/` (`rtl/cpu/tg68k/PROVENANCE.md`). LGPL-3.0 code in a GPL-3.0 work is direct.
Obligations: publish the source, keep its headers.

### jotego/jt8051, as jt8052 — GPL-3.0-or-later

jotego's JT8051 (`jtcores`, `modules/jt8051`) as forked into an 8052 by the Vamphalf and Eolith
cores, copied from Arcade-Eolith_MiSTer: `rtl/mcu/jt8052/`. One local change, the `p2_we` output,
marked `[DW]` (`rtl/mcu/jt8052/PROVENANCE.md`). Obligations: publish the source, keep the change
notices.

### jotego/jt6295 — GPL-3.0

<https://github.com/jotego/jt6295> at `7d76b0be8cd8f85f3ae741178c9830b20e2071a1`, via
Arcade-Fuuki_MiSTer: `rtl/sound/jt6295/`, unmodified. `oki_rom_bridge.sv` and `sample_cache.sv`
(Fuuki's, after Psikyo's) feed its ROM bus (`rtl/sound/PROVENANCE.md`). Obligations: publish the
source.

### Sorgelig's SDRAM controller — GPL-3.0-or-later

`rtl/memory/sdram/sdram.sv`: Sorgelig's `sdram.v`, extended for burst-4 reads;
`sdram_upstream_reference.sv` is the unmodified upstream for diffing
(`rtl/memory/sdram/PROVENANCE.md`). Obligations: publish the source, keep the change notices in its
header.

### rmonic79's CRT Adjust — GPL-3.0-or-later

`rtl/video/crt_adjust.sv` (from Arcade-Raiden_MiSTer, one local fix marked `LOCAL FIX` in the file)
and `rtl/video/crt_vsize.sv` (from MiSTer-CRT-Adjust at `c682de9`, unmodified). Obligations: publish
the source, keep the change notice.

### JimmyStones/Hiscores_MiSTer — GPL-3.0-or-later

`rtl/hiscore.v`, Alan Steremberg and Jim Gregory, unmodified. Obligations: publish the source.

### Sorgelig's screen rotation — GPL-2.0-or-later

`rtl/video/screen_rotate_two.sv`, unmodified. GPL-2.0-or-later into a GPL-3.0-or-later work is
direct.

### MiSTer-devel/Template_MiSTer — GPL-2.0-or-later (`sys/`)

The framework, unmodified. Its grant is "or later", which is what lets it combine with GPL-3 code.

## Reference material, not code

MAME (<https://github.com/mamedev/mame>, `src/mame/misc/dreamwld.cpp` and the devices it uses,
BSD-3-Clause and GPL-2.0-or-later per file) is the reference for the hardware's behaviour; no MAME
source is compiled into the core. `scripts/oki_model.py` transcribes `okim6295.cpp` and
`okiadpcm.cpp` for the sound benches; `rtl/mame_keys.sv` takes MAME's default key list.

## Release checklist

- every `PROVENANCE.md` current, and each modified vendored file carries its change notice
- `sys/` unmodified against Template_MiSTer
- `LICENSE` is the GPLv3 text
