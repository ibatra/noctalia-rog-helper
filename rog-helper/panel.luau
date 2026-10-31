--!nonstrict
-- ROG helper panel: G-Helper's one-glance layout, drawn in Pond's design
-- language (butterfly.so) like the shell's Wi-Fi / Bluetooth / battery panels.
--
-- Main view: header (battery, charger, CPU, dGPU), Performance, GPU, Screen,
-- Battery limit, Keyboard, Awake, and a row that opens the Power, Fans,
-- Lighting and Sleep views.
--
-- Every read and write goes through bin/rogctl (bin/awakectl for Sleep & lid,
-- drawn by awake_view.luau), so the panel holds no hardware logic. A picked
-- option shows as selected straight away and snaps back to the real state on
-- the next snapshot (e.g. a cancelled password prompt).

local PLUGIN_DIR = noctalia.pluginDir() or noctalia.expandPath("~/.local/share/noctalia-plugins/rog-helper")
local ROGCTL = PLUGIN_DIR .. "/bin/rogctl"
local AWAKECTL = PLUGIN_DIR .. "/bin/awakectl"
local Common = require("./common.luau")
local Awake = require("./awake_view.luau")
local Power = require("./power_view.luau")
local Fans = require("./fans_view.luau")
local Lighting = require("./lighting_view.luau")
local REFRESH_EVERY = 5 -- seconds
local REFRESH_EXTRA_EVERY = 15 -- seconds, sub-views only (several asusctl calls)

local st = {} -- main snapshot (rogctl status)
local ex = {} -- extra snapshot (rogctl status-extra), loaded for the sub-views
local picked = {} -- section -> option id chosen but not yet confirmed
local notes = {} -- section -> { text, tone, expires }
local busy = {} -- section -> true while its command runs
local hover = ""
local ticks = 0
local isOpen = false
local loading, loadingExtra = false, false
local reloadAgain, reloadExtraAgain = false, false -- asked for while one was in flight

local view = "main" -- main | power | fans | lighting | sleep

-- ── helpers ───────────────────────────────────────────────────────────────────

local function num(v) return tonumber(v or "") end

-- Capability flag from rogctl ("has_*"). Unknown until the first snapshot,
-- which counts as present so nothing flickers away on open.
local function has(t, key) return t["has_" .. key] ~= "0" end

local parse = Common.parse

local function setNote(section, text, tone, seconds)
  if text == nil or text == "" then
    notes[section] = nil
  else
    notes[section] = { text = text, tone = tone or "muted", expires = seconds and (noctalia.nowMs() + seconds * 1000) or nil }
  end
end

local function notifyAction(body)
  noctalia.runAsync({ "noctalia", "msg", "notification-show", "ROG helper", body })
end

local render

-- A fresh snapshot replaces the optimistic picks, except for sections whose
-- command is still running (e.g. Silent waiting on the password prompt).
local function dropSettledPicks()
  for k in pairs(picked) do
    if not busy[k] then picked[k] = nil end
  end
end

local function refresh()
  if loading then
    reloadAgain = true -- the snapshot in flight may predate a change
    return
  end
  loading = true
  noctalia.runAsync({ ROGCTL, "status" }, function(res)
    loading = false
    if res.exitCode == 0 then
      st = parse(res.stdout)
      dropSettledPicks()
      noctalia.state.set("rog.status", st)
    end
    if reloadAgain then
      reloadAgain = false
      refresh()
    end
    if isOpen then render() end
  end, 5000)
end

local function refreshExtra()
  if loadingExtra then
    reloadExtraAgain = true
    return
  end
  loadingExtra = true
  noctalia.runAsync({ ROGCTL, "status-extra" }, function(res)
    loadingExtra = false
    if res.exitCode == 0 then
      ex = parse(res.stdout)
      dropSettledPicks()
    end
    if reloadExtraAgain then
      reloadExtraAgain = false
      refreshExtra()
    end
    if isOpen then render() end
  end, 8000)
end

-- Sub-views that read rogctl status-extra (Sleep reads awakectl instead).
local function extraView(v)
  return v == "power" or v == "fans" or v == "lighting"
end

-- Runs one command of bin (rogctl or awakectl) for a section: the pick shows
-- at once, the section is busy until it returns, the outcome becomes a note,
-- and refreshFn reloads that tool's snapshot.
local function actWith(bin, refreshFn, section, id, args, after)
  if busy[section] then return end
  busy[section] = true
  picked[section] = id
  setNote(section, nil)
  render()

  local argv = { bin }
  local dry = noctalia.getConfig("dry_run") == true
  if dry then argv[#argv + 1] = "--dry-run" end
  for _, a in ipairs(args) do argv[#argv + 1] = a end

  -- 60 s is the host maximum; enough for a polkit password prompt.
  noctalia.runAsync(argv, function(res)
    busy[section] = nil
    local out = noctalia.string.trim(res.stdout or "")
    Common.notifyDryRun(res.stderr, dry)
    if res.timedOut then
      setNote(section, "Timed out", "error", 6)
    elseif res.exitCode == 3 then
      setNote(section, out, "muted", 8)
    elseif res.exitCode ~= 0 then
      setNote(section, out ~= "" and out or "Failed", "error", 8)
    elseif out ~= "" and out ~= "Restart required" then
      setNote(section, out, "muted", 10)
    end
    -- Only outcomes that need the user to do something become notifications.
    if bin == ROGCTL and res.exitCode == 0 and not dry then
      if out:find("next login", 1, true) then notifyAction("Eco switches at your next login") end
      if out == "Restart required" then notifyAction("Restart to finish switching to Ultimate") end
    end
    picked[section] = nil
    refreshFn()
    if after == "extra" or extraView(view) then refreshExtra() end
  end, 60000)
end

local function act(section, id, args, after)
  actWith(ROGCTL, refresh, section, id, args, after)
end

local function actAwake(section, id, args)
  actWith(AWAKECTL, Awake.refresh, section, id, args)
end

-- ── derived state ─────────────────────────────────────────────────────────────

local PERF_LABEL = { silent = "Silent", balanced = "Balanced", turbo = "Turbo" }

local function gpuMode()
  local mux, booted = st.mux, st.booted_ultimate == "1"
  if st.optimized == "1" then return "optimized" end
  if mux == "0" then return "ultimate" end
  if booted then return "standard" end
  if st.dgpu_disable == "1" or st.pending_gpu == "eco" then return "eco" end
  return "standard"
end

local function needsRestart()
  local booted = st.booted_ultimate == "1"
  return st.pending_reboot == "1" or (st.mux == "0" and not booted) or (st.mux == "1" and booted)
end

local function inUltimate()
  return st.mux == "0" or st.booted_ultimate == "1"
end

local function dgpuText()
  local d = st.dgpu
  if d == "off" or st.dgpu_disable == "1" then return "dGPU off" end
  if d == "active" then return "dGPU active" end
  if d == "suspended" then return "dGPU asleep" end
  return "dGPU"
end

local function dgpuActive() return dgpuText() == "dGPU active" end

local function batteryGlyph()
  local pct = num(st.battery) or 0
  if st.ac == "1" then return "battery-charging" end
  if pct >= 88 then return "battery-4" end
  if pct >= 60 then return "battery-3" end
  if pct >= 35 then return "battery-2" end
  if pct >= 12 then return "battery-1" end
  return "battery"
end

local function chargerText()
  if st.ac ~= "1" then return nil end
  if st.charge_mode == "2" then return "USB-C" end
  if st.charge_mode == "1" then return "Adapter" end
  return "Plugged in"
end

-- ── building blocks ───────────────────────────────────────────────────────────
-- Two control families with a clear job each:
--   tiles  - the big mode switches (Performance, GPU): separate slabs.
--   tracks - every smaller choice: one rounded track, the active option a
--            tinted segment inside it, the rest bare text.
-- Labels are dropped wherever an icon or the options themselves say enough.
--
-- Pond's look: #262626 slabs with 12 px corners,
-- #303030 under the pointer (never an accent fill), a sparing lavender for
-- what is picked (Pond's selected battery profile: lavender at 10%, its icon
-- in colour), Onest Medium with secondary text at 50-70%, #3D3D3D hairlines,
-- serif titles. Palette roles, so the Pond palette supplies the greys.

local R_TILE = 12
local FILL_IDLE = "surface_container" -- Pond #262626: tiles, tracks, chips, cards
local FILL_HOVER = "hover"            -- Pond #303030
local FILL_ON = "primary/0.15"        -- lavender tint for the picked option
local LINE_ON = "primary/0.4"         -- and its 1 px hairline (tiles, track segments, chips)
local MONO = "IBM Plex Mono"          -- Pond's numeral face (readouts, temperatures, watts)
local HAIRLINE = "outline_variant"    -- Pond #3D3D3D
local TITLE_FONT = "Instrument Serif" -- stands in for Pond's Gramercy
local ATTENTION = "#ff9f67"           -- Pond's orange
-- Pond's pastel accents. A picked mode tile is tinted in its own colour, like
-- Pond's power profiles: eco lime, balanced lavender, performance orange.
local LIME, LAVENDER, ORANGE = "#cbe25b", "#cba6f7", "#ff9f67"
-- Bare items (track options, nav buttons) still need an explicit fill: a nil
-- fill leaves a retained node's previous fill in place, so a hover highlight
-- would never clear.
local FILL_NONE = "surface_container/0.01"

-- Content colour: full white on a picked or hovered option, otherwise `idle`
-- (the 60% secondary text).
local function ink(active, hovered, idle)
  if active or hovered then return "on_surface" end
  return idle
end

-- A render() made inside a pointer callback is not always applied (seen with
-- a burst of enter/leave events: the panel showed the state one step behind),
-- which left hover highlights stuck and piling up. So hover changes also queue
-- one more render for after the callback returns; runAsync's completion is the
-- only deferred hook the plugin API has. Bursts share the one queued render.
local renderQueued = false
local function renderSoon()
  if renderQueued then return end
  renderQueued = true
  noctalia.runAsync({ "true" }, function()
    renderQueued = false
    if isOpen then render() end
  end, 2000)
end

-- One onHover closure per item, bound to that item's key, so the key never
-- depends on which sibling registered a shared handler last.
-- While the panel opens and lays out, Noctalia sends stray enter events for
-- whatever lands under a stale pointer position (the pointer is still on the
-- bar), which lit an item nobody pointed at. Enters in that window are dropped.
local HOVER_SETTLE_MS = 400
local openedAt = 0

local function hoverHandler(key)
  return function(state)
    local entering = state == "true" or state == true
    if entering and noctalia.nowMs() - openedAt < HOVER_SETTLE_MS then return end
    if entering then hover = key elseif hover == key then hover = "" end
    render()
    renderSoon()
  end
end

-- "tertiary" is the warning tone the views pass (awake_view.luau and its
-- tests); in the Pond palette tertiary is the success lime, so warnings take
-- Pond's orange instead.
local function caption(text, color)
  if color == "tertiary" then color = ATTENTION end
  return ui.label({ text = text, fontSize = 12, color = color or "on_surface/0.5", maxLines = 3 })
end

-- Sub-view section label, with optional trailing detail or node.
local function label(title, trailing)
  local kids = { ui.label({ text = title, fontSize = 12, fontWeight = "medium", color = "on_surface/0.5", flexGrow = 1 }) }
  if type(trailing) == "string" and trailing ~= "" then
    kids[#kids + 1] = caption(trailing)
  elseif type(trailing) == "table" then
    kids[#kids + 1] = trailing
  end
  return ui.row({ align = "center", gap = 8, height = 18 }, kids)
end

local function tile(section, opt, selected)
  local key = section .. ":" .. opt.id
  local active = opt.id == selected
  local enabled = opt.enabled ~= false and not busy[section]
  local hovered = not active and enabled and hover == key
  -- The picked tile takes one accent throughout, like Pond's selected power
  -- profile: the accent at ~15% for the fill, a hairline and the icon in the
  -- accent itself. Its own tint (#rrggbb: Pond's profile colours on
  -- Performance and GPU) or lavender. The rest stay white at 60%.
  local onFill, onBorder, onGlyph = FILL_ON, LINE_ON, "primary"
  if opt.tint then onFill, onBorder, onGlyph = opt.tint .. "26", opt.tint .. "66", opt.tint end -- 15% / 40%
  local fill = active and onFill or (hovered and FILL_HOVER or FILL_IDLE)
  local glyphColor = active and onGlyph or (hovered and "on_surface" or "on_surface/0.6")
  return ui.column({
    key = key, flexGrow = 1, gap = 4, paddingV = 10, radius = R_TILE, fill = fill, align = "center",
    border = active and onBorder or FILL_NONE, borderWidth = 1,
    opacity = (opt.enabled == false) and 0.35 or 1,
    onClick = enabled and not active and opt.onClick or nil,
    onHover = hoverHandler(key),
  }, {
    ui.glyph({ name = opt.glyph, size = 19, color = glyphColor }),
    ui.label({ text = opt.label, fontSize = 12, fontWeight = "medium", color = ink(active, hovered, "on_surface/0.7"), maxLines = 1 }),
  })
end

local function segment(section, opt, selected)
  local key = section .. ":" .. opt.id
  local active = opt.id == selected
  local enabled = opt.enabled ~= false and not busy[section]
  local hovered = not active and enabled and hover == key
  local fill = active and FILL_ON or (hovered and FILL_HOVER or FILL_NONE)
  -- The picked segment matches the picked tile and chip: the accent at 15%
  -- with a 40% hairline. Every segment carries the 1 px border (invisible when
  -- not picked) so picking one never shifts the track.
  return ui.row({
    key = key, flexGrow = 1, paddingV = 6, radius = 8, fill = fill, justify = "center", align = "center",
    border = active and LINE_ON or FILL_NONE, borderWidth = 1,
    opacity = (opt.enabled == false) and 0.35 or 1,
    onClick = enabled and not active and opt.onClick or nil,
    onHover = hoverHandler(key),
  }, {
    ui.label({ text = opt.label, fontSize = 12, fontWeight = "medium", color = ink(active, hovered, "on_surface/0.6") }),
  })
end

local function choices(kind, section, options, selected)
  local children = {}
  for _, o in ipairs(options) do
    children[#children + 1] = (kind == "tile" and tile or segment)(section, o, selected)
  end
  if kind == "tile" then return ui.row({ gap = 6 }, children) end
  return ui.row({ gap = 2, padding = 3, radius = 10, fill = FILL_IDLE }, children)
end

-- A settings row whose leading glyph stands in for its label.
local function iconRow(glyph, control, trailing)
  local kids = {
    ui.column({ width = 22, align = "center" }, { ui.glyph({ name = glyph, size = 16, color = "on_surface/0.6" }) }),
    ui.column({ flexGrow = 1 }, { control }),
  }
  if trailing then kids[#kids + 1] = trailing end
  return ui.row({ align = "center", gap = 8 }, kids)
end

-- Pill that toggles on its own (used for multi-select flags). On is the
-- lavender tint with a lavender hairline (no check glyph: four of them did not
-- fit the 316 px card); off keeps an invisible hairline so nothing shifts.
local function chip(key, text, on, onClick)
  local hovered = not on and hover == key
  local fill = on and FILL_ON or (hovered and FILL_HOVER or FILL_IDLE)
  local color = ink(on, hovered, "on_surface/0.6")
  return ui.row({ key = key, paddingH = 10, paddingV = 6, radius = 10, fill = fill, align = "center",
    border = on and LINE_ON or FILL_NONE, borderWidth = 1,
    onClick = onClick, onHover = hoverHandler(key) }, {
    ui.label({ text = text, fontSize = 12, fontWeight = "medium", color = color, maxLines = 1 }),
  })
end

local function noteRow(section, extra)
  local n = notes[section]
  if n and n.expires and noctalia.nowMs() > n.expires then
    notes[section] = nil
    n = nil
  end
  if not n and not extra then return nil end
  local children = {}
  if n then
    children[#children + 1] = ui.label({
      text = n.text, fontSize = 12, maxLines = 2, flexGrow = 1,
      color = n.tone == "error" and "error" or "on_surface/0.6",
    })
  end
  if extra then children[#children + 1] = extra end
  return ui.row({ align = "center", gap = 8 }, children)
end

local function section(parts, gap)
  local kids = {}
  for i = 1, 16 do -- not ipairs: optional parts are nil holes
    if parts[i] then kids[#kids + 1] = parts[i] end
  end
  return ui.column({ gap = gap or 6 }, kids)
end

-- Optional `value` follows the word in the mono numeral face ("CPU" + "46°").
local function stat(glyph, text, color, value)
  local c = color or "on_surface/0.5"
  local kids = {
    ui.glyph({ name = glyph, size = 13, color = c }),
    ui.label({ text = text, fontSize = 12, color = c }),
  }
  if value then kids[#kids + 1] = ui.label({ text = value, fontSize = 12, fontFamily = MONO, color = c }) end
  return ui.row({ gap = 4, align = "center" }, kids)
end

-- ── main view ─────────────────────────────────────────────────────────────────

-- The one expressive element: a live trace of power draw on battery, sampled
-- every 10 s by the bar widget, so a dGPU waking up shows as a step you can
-- see. The battery only measures draw while discharging, so on AC the trace
-- gives way to a caption of the same height.
local function drawTrace()
  if st.battery_status ~= "Discharging" then
    return ui.column({ height = 30, justify = "center", align = "start" }, { caption("Power draw shows on battery") })
  end
  local hist = noctalia.state.get("rog.draw") or {}
  local peak = 30
  for _, v in ipairs(hist) do if v > peak then peak = v end end
  local vals = {}
  for i, v in ipairs(hist) do vals[i] = v / (peak * 1.15) end
  if #vals < 2 then vals = { 0, 0 } end
  -- a transparent second series pinned at 1 keeps the scale absolute
  local ceiling = {}
  for i = 1, #vals do ceiling[i] = 1 end
  return ui.graph({ height = 30, values = vals, values2 = ceiling,
    color = dgpuActive() and ATTENTION or "primary", color2 = "primary/0", lineWidth = 1.5, fillOpacity = 0.14 })
end

-- The battery's rate is the machine's draw only while discharging. Charging,
-- it is the charge rate (shown muted, not as usage); on AC otherwise, nothing.
local function header()
  local w = math.abs(num(st.battery_watts) or 0)
  local status = st.battery_status
  local rate = nil
  if status == "Discharging" then
    rate = ui.label({ text = string.format("%.1f W", w), fontSize = 12, fontFamily = MONO, fontWeight = "medium", color = "primary" })
  elseif status == "Charging" and w > 0 then
    rate = ui.row({ gap = 4, align = "end" }, { -- Pond's charging lime; the figure in the mono numeral face
      ui.label({ text = "Charging", fontSize = 12, color = "#cbe25b" }),
      ui.label({ text = string.format("+%.0f W", w), fontSize = 12, fontFamily = MONO, color = "#cbe25b" }),
    })
  end
  return ui.column({ gap = 6 }, {
    ui.row({ align = "end", gap = 8 }, {
      -- Pond's big numbers are its serif display face
      ui.label({ text = st.battery and `{st.battery}%` or "", fontFamily = TITLE_FONT, fontSize = 30, color = "on_surface" }),
      -- paddingV 7 lifts the small text onto the serif number's baseline
      -- (bottom-aligned boxes left it 7 units low: the serif's descent)
      ui.row({ flexGrow = 1, paddingV = 7, gap = 8, align = "end" }, {
        ui.label({ text = chargerText() or "On battery", fontSize = 12, color = "on_surface/0.5", flexGrow = 1 }),
        rate,
      }),
    }),
    drawTrace(),
    ui.row({ align = "center", gap = 12 }, {
      st.cpu_temp and stat("temperature", "CPU", nil, `{st.cpu_temp}°`) or ui.spacer({}),
      ui.spacer({ flexGrow = 1 }),
      stat("device-desktop", dgpuText(), dgpuActive() and ATTENTION or nil),
    }),
  })
end

local function perfSection()
  local sel = picked.perf or st.perf
  local function pick(id) return function() act("perf", id, { "perf", id }) end end
  return section({
    choices("tile", "perf", {
      -- Pond's power profile colours: eco lime, balanced lavender, performance orange
      { id = "silent", label = "Silent", glyph = "feather", tint = LIME, onClick = pick("silent") },
      { id = "balanced", label = "Balanced", glyph = "scale", tint = LAVENDER, onClick = pick("balanced") },
      { id = "turbo", label = "Turbo", glyph = "rocket", tint = ORANGE, onClick = pick("turbo") },
    }, sel),
    noteRow("perf"),
  })
end

local function gpuSection()
  local canOff, canMux = has(st, "dgpu_disable"), has(st, "mux")
  if not canOff and not canMux then return nil end
  local sel = picked.gpu or gpuMode()
  local ult = inUltimate()
  local function pick(id) return function() act("gpu", id, { "gpu", id }) end end

  local restart = nil
  local noteText = nil
  if needsRestart() then
    noteText = "Restart required"
    restart = ui.button({
      text = "Restart", controlSize = "sm", variant = "secondary",
      onClick = function() noctalia.runAsync({ "noctalia", "msg", "session", "reboot" }) end,
    })
  elseif st.pending_gpu == "eco" and st.dgpu_disable ~= "1" then
    noteText = "Eco starts at next login"
  end
  if noteText and not notes.gpu then setNote("gpu", noteText, "muted") end
  if not noteText and notes.gpu and not notes.gpu.expires then notes.gpu = nil end

  local opts = {}
  if canOff then
    opts[#opts + 1] = { id = "eco", label = "Eco", glyph = "leaf", tint = LIME, enabled = not ult, onClick = pick("eco") }
  end
  -- the same energy scale as Performance: saving lime, everyday lavender, all-out orange
  opts[#opts + 1] = { id = "standard", label = "Standard", glyph = "device-laptop", tint = LAVENDER, onClick = pick("standard") }
  if canOff then
    opts[#opts + 1] = { id = "optimized", label = "Optimized", glyph = "sparkles", tint = LAVENDER, enabled = not ult, onClick = pick("optimized") }
  end
  if canMux then
    opts[#opts + 1] = { id = "ultimate", label = "Ultimate", glyph = "bolt", tint = ORANGE, onClick = pick("ultimate") }
  end
  return section({ choices("tile", "gpu", opts, sel), noteRow("gpu", restart) })
end

local function screenSection()
  if not has(st, "edp") then return nil end
  local low, max = st.refresh_low or "60", st.refresh_max or "240"
  local sel = picked.screen or (st.screen_auto == "1" and "auto") or (st.refresh == low and "low") or "max"
  local function pick(id) return function() act("screen", id, { "refresh", id }) end end
  return section({
    iconRow("device-laptop", choices("segment", "screen", {
      { id = "low", label = `{low} Hz`, onClick = pick("low") },
      { id = "max", label = `{max} Hz`, onClick = pick("max") },
      { id = "auto", label = "Auto", onClick = pick("auto") },
    }, sel)),
    noteRow("screen"),
  })
end

local function batterySection()
  if not has(st, "limit") then return nil end
  local cur = num(st.limit)
  local values = { 60, 80, 100 }
  if cur and cur ~= 60 and cur ~= 80 and cur ~= 100 then
    table.insert(values, cur)
    table.sort(values)
  end
  local sel = picked.limit or (cur and tostring(cur))
  local opts = {}
  for _, v in ipairs(values) do
    local id = tostring(v)
    opts[#opts + 1] = { id = id, label = `{v}%`, onClick = function() act("limit", id, { "limit", id }) end }
  end
  local once = ui.button({
    glyph = "battery-charging", variant = "ghost", controlSize = "sm", glyphSize = 15,
    tooltip = "Charge to 100% once", enabled = not busy.oneshot,
    onClick = function() act("oneshot", "go", { "oneshot" }) end,
  })
  return section({
    iconRow("battery-2", choices("segment", "limit", opts, sel), once),
    noteRow("limit"),
    noteRow("oneshot"),
  })
end

-- Keyboard backlight levels, on the main view and in the Lighting view.
local function kbdOptions()
  local opts = {}
  for i, n in ipairs({ "Off", "Low", "Medium", "High" }) do
    local id = tostring(i - 1)
    opts[#opts + 1] = { id = id, label = n, onClick = function() act("kbd", id, { "kbd", id }) end }
  end
  return opts
end

local function keyboardSection()
  if not has(st, "kbd") then return nil end
  return section({ iconRow("keyboard", choices("segment", "kbd", kbdOptions(), picked.kbd or st.kbd)), noteRow("kbd") })
end

local function navButton(id, glyph, text)
  local key = "nav:" .. id
  local color = ink(false, hover == key, "on_surface/0.6")
  return ui.row({
    key = key, flexGrow = 1, gap = 6, paddingV = 8, radius = 10,
    fill = hover == key and FILL_HOVER or FILL_NONE, justify = "center", align = "center",
    onClick = function()
      view = id
      hover = ""
      if id == "sleep" then Awake.refresh() else refreshExtra() end
      render()
    end,
    onHover = hoverHandler(key),
  }, {
    ui.glyph({ name = glyph, size = 15, color = color }),
    ui.label({ text = text, fontSize = 12, fontWeight = "medium", color = color }),
  })
end

local function hairline(key)
  return ui.row({ key = key, height = 1, fill = HAIRLINE }, { ui.spacer({ flexGrow = 1 }) })
end

-- Pond's panel header: a serif title (a back button first on a sub-view, a
-- detail on the right) over a hairline.
local function titleBlock(key, title, detail, back)
  local kids = {}
  if back then kids[#kids + 1] = back end
  kids[#kids + 1] = ui.label({ text = title, fontFamily = TITLE_FONT, fontSize = 22, color = "on_surface", maxLines = 1, flexGrow = 1 })
  if detail and detail ~= "" then
    kids[#kids + 1] = ui.label({ text = detail, fontSize = 12, color = "on_surface/0.5", maxLines = 1, maxWidth = 170, textAlign = "end" })
  end
  return ui.column({ key = key, gap = 12, paddingH = 2 }, {
    ui.row({ height = 32, align = "center", gap = 10 }, kids),
    hairline(key .. ":line"),
  })
end

-- Children without the nil holes left by sections this machine lacks.
local function packed(...)
  local out = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if v then out[#out + 1] = v end
  end
  return out
end

local function mainView()
  return {
    titleBlock("title:main", "Laptop"),
    header(),
    ui.column({ gap = 8 }, packed(perfSection(), gpuSection())),
    ui.column({ gap = 8 }, packed(screenSection(), batterySection(), keyboardSection(), Awake.mainRow(), noteRow("awake_quick"))),
    ui.column({ gap = 8 }, {
      hairline("nav:line"),
      ui.row({ gap = 4 }, {
        navButton("power", "gauge", "Power"),
        navButton("fans", "propeller", "Fans"),
        navButton("lighting", "bulb", "Lighting"),
        navButton("sleep", "moon", "Sleep"),
      }),
    }),
  }
end

-- ── sub-view chrome ───────────────────────────────────────────────────────────

-- Pond's back button: 32x32, 10 px corners, #262626 with a hairline.
local function subHeader(title, detail)
  local hovered = hover == "back"
  local back = ui.row({
    key = "back", width = 32, height = 32, radius = 10, align = "center", justify = "center",
    fill = hovered and FILL_HOVER or FILL_IDLE, border = HAIRLINE, borderWidth = 1,
    onClick = function()
      view = "main"
      hover = ""
      render()
    end,
    onHover = hoverHandler("back"),
  }, { ui.glyph({ name = "chevron-left", size = 16, color = "on_surface" }) })
  return titleBlock("title:" .. title, title, detail, back)
end

-- Pond's toggle: a 54x28 outlined pill with faint off/on markers; the knob is
-- red with a dash when off and green with a bar when on (Pond's literals).
-- The whole row is the click target; onChange gets "true"/"false" like
-- ui.toggle's.
local function pondToggle(on, hovered)
  local knob = ui.column({ width = 24, height = 24, radius = 12, align = "center", justify = "center",
    fill = on and "#0c3723" or "#613129" }, {
    on and ui.box({ width = 4, height = 12, radius = 2, fill = "#b0ff4f" })
      or ui.box({ width = 12, height = 4, radius = 2, fill = "#fb9b89" }),
  })
  local ghostOff = ui.row({ width = 24, height = 24, align = "center", justify = "center" }, {
    ui.box({ width = 13, height = 5, radius = 2.5, fill = FILL_NONE, border = "#e7e7e74d", borderWidth = 1 }),
  })
  local ghostOn = ui.row({ width = 24, height = 24, align = "center", justify = "center" }, {
    ui.box({ width = 5, height = 13, radius = 2.5, fill = FILL_NONE, border = "#e7e7e74d", borderWidth = 1 }),
  })
  return ui.row({
    width = 54, height = 28, radius = 14, padding = 2, gap = 2, align = "center",
    fill = hovered and FILL_HOVER or FILL_NONE, border = HAIRLINE, borderWidth = 1,
  }, on and { ghostOff, knob } or { knob, ghostOn })
end

local function toggleRow(title, checked, onChange, detail)
  local key = "toggle:" .. title
  local hovered = hover == key
  local kids = { ui.label({ text = title, fontSize = 13, fontWeight = "medium", color = "on_surface", flexGrow = 1, maxLines = 1 }) }
  if detail then kids[#kids + 1] = caption(detail) end
  kids[#kids + 1] = pondToggle(checked, hovered)
  return ui.row({
    key = key, align = "center", gap = 8, height = 36, radius = 12, -- no inset: label and toggle share the edges of the sliders and selectors
    onClick = function() onChange(checked and "false" or "true") end,
    onHover = hoverHandler(key),
  }, kids)
end

-- The Sleep view and the main-view Awake row are drawn by awake_view.luau from
-- these blocks; mainView only calls into it at render time, so it can be set
-- up here, once subHeader and toggleRow exist.
Awake.setup({
  choices = choices, iconRow = iconRow, label = label, section = section, toggleRow = toggleRow,
  subHeader = subHeader, caption = caption, noteRow = noteRow, packed = packed,
  picked = picked, bin = AWAKECTL,
  render = function() if isOpen then render() end end,
  act = actAwake,
  hover = function() return hover end,
})

local function loadingView(title)
  return { subHeader(title), caption("Reading…") }
end

-- The Power, Fans and Lighting views (power_view.luau, fans_view.luau,
-- lighting_view.luau) are drawn from these blocks, act through rogctl, and
-- read the snapshots at render time.
local blocks = {
  caption = caption, label = label, section = section, choices = choices, iconRow = iconRow,
  chip = chip, noteRow = noteRow, stat = stat, packed = packed, subHeader = subHeader,
  toggleRow = toggleRow, loadingView = loadingView, hoverHandler = hoverHandler, kbdOptions = kbdOptions,
  R_TILE = R_TILE, FILL_IDLE = FILL_IDLE, PERF_LABEL = PERF_LABEL,
  num = num, has = has, picked = picked, busy = busy,
  st = function() return st end,
  ex = function() return ex end,
  act = act,
  render = function() render() end,
}
Power.setup(blocks)
Fans.setup(blocks)
Lighting.setup(blocks)

-- ── render / lifecycle ────────────────────────────────────────────────────────

-- The panel is height = "content" (plugin.toml): the card hugs the main view
-- and grows up from the bottom-left corner it is pinned to, so there is no
-- empty strip above the nav row when no note or Restart row shows. A ui.scroll
-- has no natural height of its own, so the main view's rows only go in one
-- when they would run past the card's maximum; then a fixed-height column
-- holds it, header and nav row staying put. The sub-views are long (Sleep,
-- Lighting), so they always take a fixed card (the old 592) and scroll; the
-- main view may grow a little past that while notes show.
local MAX_H = 640    -- plugin.toml max_height
local SUB_H = 592    -- the sub-views' card
local PANEL_PAD = 14 -- Noctalia's padding on each side of the content
local ROOT_GAP = 14  -- between the header, the rows and the nav row
-- a little over the real heights (Onest's line is 1.275 em, the serif's 1.3):
-- header = 32 row + 12 + hairline; nav = hairline + 8 + 8/15/8 button;
-- dry-run caption = one 12 px line + the gap
local HEAD_H, FOOT_H, DRY_H = 46, 42, 30
-- main-view rows with every section present and no notes: the battery
-- header (39 + 6 + 30 + 6 + 15), two 58 tile rows, four 33 tracks and the
-- gaps come to 406; round 2's screenshot measured about 402
local MAIN_ROWS_H = 410
local NOTE_LINE = 16 -- one 12 px line
local RESTART_H = 14 -- the Restart button over its note's one line

-- ui.scroll insets its viewport by a fixed 4 px left/right and 8 px top/bottom
-- in surface pixels (not scaled by ui_scale), so
-- the plain column gets the same inset and nothing shifts between the two.
local function readUiScale()
  for _, p in ipairs({ "~/.local/state/noctalia/settings.toml", "~/.config/noctalia/config.toml" }) do
    local ok, s = pcall(noctalia.readFile, noctalia.expandPath(p))
    if ok and type(s) == "string" then
      local v = tonumber(s:match("\n%s*ui_scale%s*=%s*([%d%.]+)") or s:match("^%s*ui_scale%s*=%s*([%d%.]+)") or "")
      if v and v > 0.3 and v < 4 then return v end
    end
  end
  return 1
end
local UI_SCALE = readUiScale()
local SCROLL_PAD_H = 4 / UI_SCALE
local SCROLL_PAD_V = 8 / UI_SCALE

-- Estimated natural height of the main view's rows: the base plus whatever
-- notes and the Restart row add right now (an over-estimate only switches to
-- the scrolling layout a little early).
local function mainRowsHeight()
  local h = MAIN_ROWS_H + 2 * SCROLL_PAD_V
  local now = noctalia.nowMs()
  for _, n in pairs(notes) do
    if not (n.expires and now > n.expires) then
      h += 8 + NOTE_LINE * (#(n.text or "") > 38 and 2 or 1)
    end
  end
  if needsRestart() then h += RESTART_H end
  return h
end

render = function()
  local body
  if view == "power" then body = Power.view()
  elseif view == "fans" then body = Fans.view()
  elseif view == "lighting" then body = Lighting.view()
  elseif view == "sleep" then body = Awake.view()
  else body = mainView() end
  local items = {}
  for i = 1, 24 do
    if body[i] then items[#items + 1] = body[i] end
  end
  local head = table.remove(items, 1)
  local foot = view == "main" and table.remove(items) or nil
  local dry = noctalia.getConfig("dry_run") == true and caption("Dry run: buttons only show their commands", ATTENTION) or nil

  local room = (view == "main" and MAX_H or SUB_H) - 2 * PANEL_PAD - HEAD_H - ROOT_GAP
  if foot then room -= (FOOT_H + ROOT_GAP) end
  if dry then room -= DRY_H end
  local rows = nil
  if #items > 0 then
    if view == "main" and mainRowsHeight() <= room then
      rows = ui.column({ key = "rows:plain", gap = 14, paddingH = SCROLL_PAD_H, paddingV = SCROLL_PAD_V }, items)
    else
      rows = ui.column({ key = "rows:box", height = room }, {
        ui.scroll({ key = "rows:scroll", flexGrow = 1, gap = 14 }, items),
      })
    end
  end
  local kids = packed(dry, head, rows, foot)
  -- keyed by view so retained nodes never carry props across views
  panel.render(ui.column({ gap = ROOT_GAP }, { ui.column({ key = "view:" .. view, gap = ROOT_GAP }, kids) }))
end

-- The dry_run setting reaches the systemd units through a flag file (the bar
-- widget keeps it in sync too).
Common.syncDryRunFlag()

function onConfigChanged()
  Common.syncDryRunFlag()
  if isOpen then render() end
end

noctalia.state.watch("rog.draw", function(_v)
  if isOpen and view == "main" then render() end
end)

function onOpen(context)
  isOpen = true
  openedAt = noctalia.nowMs()
  hover = ""
  ticks = 0
  Lighting.readTheme()
  st = noctalia.state.get("rog.status") or st
  if extraView(context) then
    view = context
    refreshExtra()
  elseif context == "sleep" then
    view = context
  else
    view = "main"
  end
  render()
  refresh()
  Awake.refresh()
  panel.setWantsSecondTicks(true)
end

function onClose()
  isOpen = false
  hover = ""
  Power.reset()
  panel.setWantsSecondTicks(false)
end

function update()
  if not isOpen then return end
  ticks += 1
  if ticks % REFRESH_EVERY == 0 then
    refresh()
    Awake.refresh() -- the time left, and sessions the watcher ended
  end
  -- external changes (Fn keys, asusctl, rog-control-center) show up in the
  -- sub-views too
  if extraView(view) and ticks % REFRESH_EXTRA_EVERY == 0 then
    refreshExtra()
  end
end

-- Scriptable entry point, also used for testing without a pointer:
--   noctalia msg plugin ishaan/rog-helper:panel all act gpu:eco
--   noctalia msg plugin ishaan/rog-helper:panel all view fans
--   noctalia msg plugin ishaan/rog-helper:panel all act awake:toggle
-- awake: toggle | stop | start-<system|screen>-<mins|inf> | set-<key>-<value>
local VERBS = { perf = "perf", gpu = "gpu", screen = "refresh", limit = "limit", kbd = "kbd" }
-- the awakectl settings `act awake:set-…` may change
local AWAKE_SETTINGS = {
  kind = true, mins = true, lid_ac = true, lid_bat = true, lid_screen = true, lid_monitor = true,
  power_key = true, stop_battery = true, stop_unplug = true, stop_hot = true,
}

local function awakeIpc(cmd)
  if cmd == "toggle" then
    actAwake("awake_quick", "x", { "toggle" })
  elseif cmd == "stop" then
    actAwake("awake_quick", "none", { "stop" })
  else
    local kind, mins = cmd:match("^start%-(%a+)%-(%w+)$")
    if kind then
      actAwake("awake_kind", kind, { "start", kind, mins })
      return
    end
    local key, value = cmd:match("^set%-([%a_]+)%-(%w+)$")
    if key and AWAKE_SETTINGS[key] then actAwake(key, value, { "set", key .. "=" .. value }) end
  end
end

function onIpc(event, payload)
  if type(payload) ~= "string" then return end
  if event == "view" then
    view = payload
    if view == "sleep" then Awake.refresh() elseif extraView(view) then refreshExtra() end
    render()
  elseif event == "tab" then
    Lighting.setTab(payload)
    render()
  elseif event == "act" then
    local awakeCmd = payload:match("^awake:(.+)$")
    local sec, id = payload:match("^(%a+):(%w+)$")
    if awakeCmd then
      awakeIpc(awakeCmd)
    elseif sec and VERBS[sec] then
      act(sec, id, { VERBS[sec], id })
    end
  elseif event == "run" then
    -- raw rogctl args, space separated (testing): "aura static ffffff"
    local args = {}
    for a in payload:gmatch("%S+") do args[#args + 1] = a end
    act("ipc", "x", args, "extra")
  end
end
