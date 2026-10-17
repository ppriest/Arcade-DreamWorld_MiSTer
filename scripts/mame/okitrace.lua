-- Every write to the OKI and OKI-bank registers, with the machine time, for scripts/oki_trace.py.
-- dreamwld.cpp: oki1 at 0xC00018, its bank at 0xC0000F, oki2 at 0xC00028, its bank at 0xC0002F
-- (byte handlers on the 68020's 32-bit bus). One line per write: "seconds offset data mask",
-- the tap's own 32-bit-aligned offset and lanes. Run through run.lua; stops after CORE_SECONDS.
local OUT  = os.getenv("CORE_OUT")
local SECS = tonumber(os.getenv("CORE_SECONDS") or "20")
local COIN = tonumber(os.getenv("CORE_COIN") or "0")
local m    = manager.machine
local sp   = m.devices[":maincpu"].spaces["program"]
local f    = assert(io.open(OUT .. "/okitrace.txt", "w"))

local function tap(lo, hi, name)
    return sp:install_write_tap(lo, hi, name, function(offset, data, mask)
        f:write(string.format("%.9f %06x %08x %08x\n", m.time:as_double(), offset, data, mask))
    end)
end
core_oki_taps = { tap(0xc0000c, 0xc0000f, "oki1bank"), tap(0xc00018, 0xc0001b, "oki1"),
                  tap(0xc00028, 0xc0002b, "oki2"), tap(0xc0002c, 0xc0002f, "oki2bank") }

local function field(name)
    for _, port in pairs(m.ioport.ports) do
        if port.fields[name] then return port.fields[name] end
    end
end
local f_coin, f_start = field("Coin 1"), field("1 Player Start")
core_oki_frame = emu.add_machine_frame_notifier(function()
    local n = m.screens[":screen"]:frame_number()
    if COIN > 0 then
        f_coin:set_value((n >= COIN and n < COIN + 6) and 1 or 0)
        f_start:set_value((n >= COIN + 90 and n < COIN + 96) and 1 or 0)
    end
    if m.time:as_double() >= SECS then
        f:close()
        print("CORE_OKITRACE_OK")
        m:exit()
    end
end)
