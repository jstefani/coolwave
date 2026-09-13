-- coolwave
-- NES / C64 / FM / formant wavetable synth
-- Port of Organelle / Pure Data Wavy.pd + main.pd
-- (separate from grainfreeze)
--
-- E1  page: WAVE / ENV / PHASE / DELAY / ARP (stops at ends)
-- E2/E3  edit two params on page
-- K1 hold + E2/E3  porta / octave (extra)
-- K2  mono/poly toggle
-- K3  randomize patch (NES-ish)
-- MIDI notes → voice synth; arp runs in Lua when MONO+ARP

engine.name = 'CoolWave'

MusicUtil = require 'musicutil'

local midi_device
local page = 1
local pages = { "WAVE", "ENV", "PHASE", "DELAY", "ARP" }
local phase_ui = 0
local ui_metro
local rand_flash = 0
local k1_held = false

local active_notes = {}   -- note -> vel (held keys)
local note_order = {}     -- as-played order
local mono = false
local arp_on = false
local arp_clock = nil
local arp_step = 1
local arp_dir = 1
local arp_playing = nil   -- currently sounding arp note id
local ARP_ID = 8000

-- UI wave 1..28 → files 0100-0103, 0105-0128 (skip 0104)
local WAVE_LABELS = {
  "NES TRI", "NES PUL1", "NES PUL2", "NES NOIZ",
  "C64 SAWD", "C64 PULS", "C64 TRI", "C64 NOIZ",
  "C64 RING", "C64 SYNC", "C64 MIX1", "C64 MIX2",
  "FM BELL", "FM BRAS", "FM CLAW", "FM REED",
  "FM BASS", "FM EP1", "FM EP2", "FM ORG",
  "FORM AH", "FORM EH", "FORM EE", "FORM OH",
  "FORM OO", "FORM MM", "FORM SS", "FORM ZZ"
}

local ARP_TYPES = { "up", "down", "updown", "order" }

-- PD-ish single-note chord expand (Maj + oct) when only one key held
local CHORD_INTERVALS = { 0, 4, 7, 12 }

local function note_hz(note)
  local oct = params:get("octave")
  return MusicUtil.note_num_to_freq(note + (oct * 12))
end

local function bang_engine()
  engine.wave(params:get("wave") - 1)
  engine.porta(params:get("porta"))
  engine.phase(params:get("phase"))
  engine.phaseLfoRate(params:get("phase_lfo_rate"))
  engine.phaseLfoAmt(params:get("phase_lfo_amt"))
  engine.attack(params:get("attack"))
  engine.decay(params:get("decay"))
  engine.sustain(params:get("sustain"))
  engine.release(params:get("release"))
  engine.cutoff(params:get("cutoff"))
  engine.res(params:get("res"))
  engine.delayTime(params:get("delay_time"))
  engine.delayFb(params:get("delay_fb"))
  engine.delayVol(params:get("delay_vol"))
  engine.delayPanRate(params:get("delay_pan_rate"))
  engine.amp(params:get("amp"))
  engine.mono(mono and 1 or 0)
  engine.octave(params:get("octave"))
  engine.arpOn(arp_on and 1 or 0)
  engine.arpSpeed(params:get("arp_speed"))
  engine.arpType(params:get("arp_type") - 1)
  engine.arpDecay(params:get("arp_decay") - 1)
end

-- true only while the user is actively turning the arp-decay control;
-- pset reads and bangs must not overwrite the saved envelope
local arp_decay_live = false

local function apply_arp_decay(preset)
  -- PD arpdecay: 0=750/1, 1=400/0.5, 2=300/0.3, 3=200/0.2, 4=50/0
  local map = {
    { 0.75, 1.0 },
    { 0.40, 0.5 },
    { 0.30, 0.3 },
    { 0.20, 0.2 },
    { 0.05, 0.0 }
  }
  local p = map[preset] or map[1]
  params:set("decay", p[1])
  params:set("sustain", p[2])
  engine.decay(p[1])
  engine.sustain(p[2])
end

local function all_notes_off()
  if arp_playing ~= nil then
    engine.noteOff(ARP_ID)
    arp_playing = nil
  end
  for note, _ in pairs(active_notes) do
    engine.noteOff(note)
  end
  active_notes = {}
  note_order = {}
  engine.allOff()
  redraw()
end

local function held_list()
  local list = {}
  for note, _ in pairs(active_notes) do
    table.insert(list, note)
  end
  table.sort(list)
  return list
end

local function arp_sequence()
  local held = held_list()
  if #held == 0 then return {} end

  -- expand single root like PD chord types (Maj)
  local notes = {}
  if #held == 1 then
    local root = held[1]
    for _, iv in ipairs(CHORD_INTERVALS) do
      table.insert(notes, root + iv)
    end
  else
    notes = held
  end

  local typ = params:get("arp_type") -- 1..4
  if typ == 1 then
    -- up
    table.sort(notes)
    return notes
  elseif typ == 2 then
    -- down
    table.sort(notes)
    local rev = {}
    for i = #notes, 1, -1 do table.insert(rev, notes[i]) end
    return rev
  elseif typ == 3 then
    -- updown (exclude duplicate ends)
    table.sort(notes)
    if #notes <= 1 then return notes end
    local seq = {}
    for i = 1, #notes do table.insert(seq, notes[i]) end
    for i = #notes - 1, 2, -1 do table.insert(seq, notes[i]) end
    return seq
  else
    -- order / as-played
    if #held == 1 then
      return notes -- expanded chord ascending
    end
    local seq = {}
    for _, n in ipairs(note_order) do
      if active_notes[n] then table.insert(seq, n) end
    end
    return seq
  end
end

local function arp_tick()
  if not (arp_on and mono) then return end
  local seq = arp_sequence()
  if #seq == 0 then
    if arp_playing ~= nil then
      engine.noteOff(ARP_ID)
      arp_playing = nil
    end
    return
  end

  if arp_step > #seq then arp_step = 1 end
  local note = seq[arp_step]
  local vel = 0.75
  -- use root key velocity if present
  for n, v in pairs(active_notes) do vel = v; break end

  if arp_playing ~= nil then
    engine.noteOff(ARP_ID)
  end
  engine.noteOn(note_hz(note), vel, ARP_ID)
  arp_playing = note
  arp_step = arp_step + 1
  if arp_step > #seq then arp_step = 1 end
  redraw()
end

local function stop_arp_clock()
  if arp_clock ~= nil then
    clock.cancel(arp_clock)
    arp_clock = nil
  end
  if arp_playing ~= nil then
    engine.noteOff(ARP_ID)
    arp_playing = nil
  end
end

local function start_arp_clock()
  stop_arp_clock()
  if not (arp_on and mono) then return end
  arp_step = 1
  arp_clock = clock.run(function()
    while true do
      local spd = params:get("arp_speed") -- Hz-ish 1..20
      local wait = 1 / math.max(0.25, spd)
      arp_tick()
      clock.sleep(wait)
    end
  end)
end

local function sync_arp()
  if arp_on and mono then
    start_arp_clock()
  else
    stop_arp_clock()
    -- re-sound held notes if leaving arp
  end
  engine.arpOn(arp_on and 1 or 0)
end

local function set_mono(v)
  -- route through the param so it is saved in psets
  params:set("mono", v and 2 or 1)
end

local function apply_mono(v)
  mono = v
  engine.mono(mono and 1 or 0)
  -- silence then resync arp
  all_notes_off()
  sync_arp()
  redraw()
end

local function voice_note_on(note, vel)
  active_notes[note] = vel
  local found = false
  for _, n in ipairs(note_order) do
    if n == note then found = true; break end
  end
  if not found then table.insert(note_order, note) end

  if arp_on and mono then
    -- arp clock handles sounding
    if arp_clock == nil then start_arp_clock() end
    return
  end

  if mono then
    -- engine mono: one voice, glide
    engine.noteOn(note_hz(note), vel, note)
  else
    engine.noteOn(note_hz(note), vel, note)
  end
end

local function voice_note_off(note)
  active_notes[note] = nil
  local new_order = {}
  for _, n in ipairs(note_order) do
    if n ~= note then table.insert(new_order, n) end
  end
  note_order = new_order

  if arp_on and mono then
    if next(active_notes) == nil then
      if arp_playing ~= nil then
        engine.noteOff(ARP_ID)
        arp_playing = nil
      end
    end
    return
  end

  if mono then
    -- legato: if other notes held, glide to newest remaining
    if #note_order > 0 then
      local n = note_order[#note_order]
      engine.noteOn(note_hz(n), active_notes[n] or 0.7, n)
    else
      engine.noteOff(note)
    end
  else
    engine.noteOff(note)
  end
end

function randomize()
  math.randomseed(math.floor(util.time() * 1000) % 2147483647)

  -- prefer NES waves often
  if math.random() < 0.55 then
    params:set("wave", math.random(1, 4))
  else
    params:set("wave", math.random(1, 28))
  end

  params:set("phase", math.random() * 0.35)
  params:set("phase_lfo_rate", math.random() < 0.4 and (0.1 + math.random() * 4) or 0)
  params:set("phase_lfo_amt", math.random() < 0.4 and (math.random() * 0.4) or 0)

  local style = math.random(1, 3)
  if style == 1 then
    -- plucky chip
    params:set("attack", 0.001 + math.random() * 0.02)
    params:set("decay", 0.05 + math.random() * 0.25)
    params:set("sustain", 0.1 + math.random() * 0.4)
    params:set("release", 0.05 + math.random() * 0.2)
  elseif style == 2 then
    -- sustain lead
    params:set("attack", 0.01 + math.random() * 0.08)
    params:set("decay", 0.1 + math.random() * 0.3)
    params:set("sustain", 0.55 + math.random() * 0.4)
    params:set("release", 0.1 + math.random() * 0.35)
  else
    -- soft pad-ish
    params:set("attack", 0.05 + math.random() * 0.3)
    params:set("decay", 0.2 + math.random() * 0.5)
    params:set("sustain", 0.5 + math.random() * 0.4)
    params:set("release", 0.2 + math.random() * 0.8)
  end

  params:set("cutoff", 600 * (2 ^ (math.random() * 3.5))) -- ~600..6800
  params:set("res", math.random() * 0.45)
  params:set("porta", mono and (math.random() * 0.18) or (math.random() * 0.05))

  params:set("delay_time", 0.1 + math.random() * 0.45)
  params:set("delay_fb", math.random() * 0.45)
  params:set("delay_vol", math.random() < 0.5 and (math.random() * 0.35) or 0.05)
  params:set("delay_pan_rate", 0.1 + math.random() * 2.5)
  params:set("amp", 0.45 + math.random() * 0.25)

  params:set("arp_speed", 4 + math.random() * 10)
  params:set("arp_type", math.random(1, 4))
  params:set("arp_decay", math.random(1, 5))

  bang_engine()
  rand_flash = 1.0
  redraw()
end

local function add_params()
  params:add_separator("coolwave")

  params:add_group("wave", 5)
  params:add_option("wave", "wave", WAVE_LABELS, 1)
  params:set_action("wave", function(v) engine.wave(v - 1); redraw() end)

  params:add_control("amp", "amp", controlspec.new(0, 1, "lin", 0.01, 0.55, ""))
  params:set_action("amp", function(v) engine.amp(v) end)

  params:add_control("porta", "portamento", controlspec.new(0, 1, "lin", 0.001, 0.0, "s"))
  params:set_action("porta", function(v) engine.porta(v) end)

  params:add_number("octave", "octave", -3, 3, 0)
  params:set_action("octave", function(v) engine.octave(v); redraw() end)

  params:add_option("mono", "voicing", { "poly", "mono" }, 1)
  params:set_action("mono", function(v) apply_mono(v == 2) end)

  params:add_group("env", 4)
  params:add_control("attack", "attack", controlspec.new(0.001, 4, "exp", 0, 0.01, "s"))
  params:set_action("attack", function(v) engine.attack(v) end)
  params:add_control("decay", "decay", controlspec.new(0.001, 4, "exp", 0, 0.2, "s"))
  params:set_action("decay", function(v) engine.decay(v) end)
  params:add_control("sustain", "sustain", controlspec.new(0, 1, "lin", 0.01, 0.7, ""))
  params:set_action("sustain", function(v) engine.sustain(v) end)
  params:add_control("release", "release", controlspec.new(0.001, 8, "exp", 0, 0.25, "s"))
  params:set_action("release", function(v) engine.release(v) end)

  params:add_group("phase", 3)
  params:add_control("phase", "phase", controlspec.new(0, 1, "lin", 0.01, 0.0, ""))
  params:set_action("phase", function(v) engine.phase(v) end)
  params:add_control("phase_lfo_rate", "phase LFO rate", controlspec.new(0, 20, "lin", 0.01, 0.0, "Hz"))
  params:set_action("phase_lfo_rate", function(v) engine.phaseLfoRate(v) end)
  params:add_control("phase_lfo_amt", "phase LFO amt", controlspec.new(0, 1, "lin", 0.01, 0.0, ""))
  params:set_action("phase_lfo_amt", function(v) engine.phaseLfoAmt(v) end)

  params:add_group("filter", 2)
  params:add_control("cutoff", "cutoff", controlspec.new(80, 16000, "exp", 0, 3500, "Hz"))
  params:set_action("cutoff", function(v) engine.cutoff(v) end)
  params:add_control("res", "resonance", controlspec.new(0, 0.95, "lin", 0.01, 0.15, ""))
  params:set_action("res", function(v) engine.res(v) end)

  params:add_group("delay", 4)
  params:add_control("delay_time", "delay time", controlspec.new(0.01, 1.4, "lin", 0.01, 0.25, "s"))
  params:set_action("delay_time", function(v) engine.delayTime(v) end)
  params:add_control("delay_fb", "delay fb", controlspec.new(0, 0.95, "lin", 0.01, 0.2, ""))
  params:set_action("delay_fb", function(v) engine.delayFb(v) end)
  params:add_control("delay_vol", "delay vol", controlspec.new(0, 1, "lin", 0.01, 0.15, ""))
  params:set_action("delay_vol", function(v) engine.delayVol(v) end)
  params:add_control("delay_pan_rate", "delay pan rate", controlspec.new(0, 8, "lin", 0.01, 0.4, "Hz"))
  params:set_action("delay_pan_rate", function(v) engine.delayPanRate(v) end)

  params:add_group("arp", 4)
  params:add_option("arp_enable", "arp", { "off", "on" }, 1)
  params:set_action("arp_enable", function(v)
    arp_on = (v == 2)
    sync_arp()
    redraw()
  end)
  params:add_control("arp_speed", "arp speed", controlspec.new(0.5, 20, "lin", 0.1, 8, "Hz"))
  params:set_action("arp_speed", function(v)
    engine.arpSpeed(v)
    if arp_on and mono then start_arp_clock() end
  end)
  params:add_option("arp_type", "arp type", ARP_TYPES, 1)
  params:set_action("arp_type", function(v) engine.arpType(v - 1); redraw() end)
  params:add_option("arp_decay", "arp decay", { "long", "med", "short", "tight", "click" }, 2)
  params:set_action("arp_decay", function(v)
    engine.arpDecay(v - 1)
    -- only reshape decay/sustain when the user turns this control.
    -- a pset read / bang must leave the saved envelope alone.
    if arp_decay_live then apply_arp_decay(v) end
  end)

  params:add_binary("all_notes_off", "all notes off", "trigger", 0)
  params:set_action("all_notes_off", function(v)
    if v == 1 then all_notes_off() end
  end)

  params:bang()
end

local function midi_event(data)
  local msg = midi.to_msg(data)
  if msg.type == "note_on" then
    if msg.vel == 0 then
      voice_note_off(msg.note)
    else
      voice_note_on(msg.note, msg.vel / 127)
    end
    redraw()
  elseif msg.type == "note_off" then
    voice_note_off(msg.note)
    redraw()
  elseif msg.type == "cc" then
    -- optional: ignore
  end
end

local function fmt_hz(v)
  return string.format("%.0fHz", v)
end

local function fmt_ms(sec)
  return string.format("%.0fms", sec * 1000)
end

local function fmt_f(v)
  return string.format("%.2f", v)
end

local function page_param_defs()
  -- returns { {id, label, format}, {id, label, format} } for E2/E3
  if page == 1 then
    return {
      { "wave", "wave", function() return WAVE_LABELS[params:get("wave")] end },
      { "cutoff", "cut", function() return fmt_hz(params:get("cutoff")) end }
    }
  elseif page == 2 then
    return {
      { "attack", "atk", function() return fmt_ms(params:get("attack")) end },
      { "release", "rel", function() return fmt_ms(params:get("release")) end }
    }
  elseif page == 3 then
    return {
      { "phase", "phase", function() return fmt_f(params:get("phase")) end },
      { "phase_lfo_amt", "amt", function() return fmt_f(params:get("phase_lfo_amt")) end }
    }
  elseif page == 4 then
    return {
      { "delay_time", "time", function() return fmt_ms(params:get("delay_time")) end },
      { "delay_fb", "fb", function() return fmt_f(params:get("delay_fb")) end }
    }
  else
    return {
      { "arp_enable", "arp", function() return (params:get("arp_enable") == 2) and "ON" or "OFF" end },
      { "arp_type", "type", function() return ARP_TYPES[params:get("arp_type")] end }
    }
  end
end

local function delta_param(id, d)
  local p = params:lookup_param(id)
  if id == "arp_decay" then arp_decay_live = true end
  if p.t == params.tNUMBER then
    params:set(id, util.clamp(params:get(id) + d, p.min, p.max))
  elseif p.t == params.tOPTION then
    params:set(id, util.clamp(params:get(id) + d, 1, #p.options))
  else
    local cs = p.controlspec
    if cs and cs.warp == "exp" then
      local v = params:get(id)
      params:set(id, util.clamp(v * (d > 0 and 1.05 or 0.95), cs.minval, cs.maxval))
    else
      params:delta(id, d)
    end
  end
  arp_decay_live = false
end

function init()
  engine.loadDir(_path.code .. "coolwave/audio")
  add_params()
  bang_engine()

  midi_device = midi.connect()
  midi_device.event = midi_event

  ui_metro = metro.init(function()
    phase_ui = phase_ui + 0.08
    if rand_flash > 0 then
      rand_flash = math.max(0, rand_flash - 0.05)
    end
    redraw()
  end, 1 / 15)
  ui_metro:start()

  -- defaults live in the param declarations (wave=1, delay_vol=0.15).
  -- do NOT re-set them here: add_params() already banged them, and hard
  -- sets at this point stomp anything a pset restores.
  bang_engine()

  redraw()
end

function cleanup()
  stop_arp_clock()
  all_notes_off()
  if ui_metro then ui_metro:stop() end
end

function key(n, z)
  if n == 1 then
    k1_held = (z == 1)
    redraw()
  elseif n == 2 and z == 1 then
    set_mono(not mono)
  elseif n == 3 and z == 1 then
    randomize()
  end
end

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, #pages)
    redraw()
    return
  end

  if k1_held then
    if page == 5 then
      if n == 2 then delta_param("arp_speed", d)
      elseif n == 3 then delta_param("arp_decay", d) end
    elseif page == 4 then
      if n == 2 then delta_param("delay_vol", d)
      elseif n == 3 then delta_param("delay_pan_rate", d) end
    elseif page == 3 then
      if n == 2 then delta_param("phase_lfo_rate", d)
      elseif n == 3 then delta_param("res", d) end
    elseif page == 2 then
      if n == 2 then delta_param("decay", d)
      elseif n == 3 then delta_param("sustain", d) end
    else
      if n == 2 then delta_param("porta", d)
      elseif n == 3 then delta_param("octave", d) end
    end
    redraw()
    return
  end

  local defs = page_param_defs()
  if n == 2 then
    delta_param(defs[1][1], d)
  elseif n == 3 then
    delta_param(defs[2][1], d)
  end
  redraw()
end

function redraw()
  screen.clear()
  screen.level(15)
  screen.move(0, 10)
  screen.text("coolwave")

  screen.level(6)
  screen.move(128, 10)
  screen.text_right(pages[page])

  -- wave name
  screen.level(15)
  screen.move(0, 24)
  screen.text(WAVE_LABELS[params:get("wave")])

  -- flags
  screen.level(10)
  screen.move(128, 24)
  local flags = (mono and "MONO" or "POLY")
  if arp_on then flags = flags .. " ARP" end
  screen.text_right(flags)

  local defs = page_param_defs()
  screen.level(12)
  screen.move(0, 40)
  screen.text(defs[1][2] .. " " .. defs[1][3]())
  screen.move(0, 52)
  screen.text(defs[2][2] .. " " .. defs[2][3]())

  -- extras line
  screen.level(5)
  screen.move(0, 63)
  if k1_held then
    if page == 5 then
      screen.text("spd " .. string.format("%.1f", params:get("arp_speed")) .. "  decay " .. ({ "long", "med", "short", "tight", "click" })[params:get("arp_decay")])
    elseif page == 4 then
      screen.text("vol " .. fmt_f(params:get("delay_vol")) .. "  pan " .. string.format("%.1f", params:get("delay_pan_rate")))
    elseif page == 3 then
      screen.text("lfo " .. string.format("%.1fHz", params:get("phase_lfo_rate")) .. "  res " .. fmt_f(params:get("res")))
    elseif page == 2 then
      screen.text("dec " .. fmt_ms(params:get("decay")) .. "  sus " .. fmt_f(params:get("sustain")))
    else
      screen.text("porta " .. fmt_ms(params:get("porta")) .. "  oct " .. string.format("%+.0f", params:get("octave")))
    end
  else
    local nheld = 0
    for _ in pairs(active_notes) do nheld = nheld + 1 end
    local extra = string.format("res %.2f", params:get("res"))
    if page == 4 then
      extra = string.format("vol %.2f pan %.1f", params:get("delay_vol"), params:get("delay_pan_rate"))
    elseif page == 2 then
      extra = string.format("dec %s sus %.2f", fmt_ms(params:get("decay")), params:get("sustain"))
    elseif page == 3 then
      extra = string.format("lfo %.1fHz", params:get("phase_lfo_rate"))
    elseif page == 5 then
      extra = string.format("spd %.1f  %s", params:get("arp_speed"), ({ "long", "med", "short", "tight", "click" })[params:get("arp_decay")])
      if not mono then extra = extra .. " (need MONO)" end
    end
    if rand_flash > 0 then
      screen.level(15)
      screen.text("RND")
    else
      screen.text(extra .. "  n" .. string.format("%.0f", nheld))
    end
  end

  screen.update()
end
