--!nonstrict
-- ROG helper panel: G-Helper's one-glance layout, drawn in Pond's design
-- language (butterfly.so) like the shell's Wi-Fi / Bluetooth / battery panels.
--
-- Main view: header (battery, its state, CPU, dGPU), the Performance tiles,
-- then one track each for GPU, Screen, Battery limit, Keyboard and Awake, and
-- a row that opens the Power, Fans, Lighting and Awake views.
--
-- Every read and write goes through bin/rogctl (bin/awakectl for Awake & lid,
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

local view = "main" -- main | power | fans | lighting | sleep (the Awake view; IPC keeps the id)

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

-- Sub-views that read rogctl status-extra (Awake reads awakectl instead).
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

-- ── building blocks ───────────────────────────────────────────────────────────
-- Two control families with a clear job each:
--   tiles  - the big mode switch (Performance): separate slabs.
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
-- Pond's power profile hues (its battery panel). A picked Performance tile
-- is tinted in its own colour: eco lime, balanced pink, performance yellow.
-- Lime also marks power going in (the head's "Charging" / "Charged"), as in
-- the battery panel; nothing else on the main view takes these hues.
local LIME, PINK, YELLOW = "#cbe25b", "#e99fff", "#ffe51d"
-- Pond's own profile icons (leaf / person / gauge) for the Performance tiles,
-- copied from its battery panel into assets/ so this plugin stands alone:
-- Pond (github bflycomputer/pond-interface) is BSD-3, see assets/LICENSE-pond.
local ASSETS = PLUGIN_DIR .. "/assets/"
-- Bare items (track options, nav buttons) still need an explicit fill: a nil
-- fill leaves a retained node's previous fill in place, so a hover highlight
-- would never clear.
local FILL_NONE = "surface_container/0.01"

-- ── the grid (pond-panels' style.luau) ──
-- Noctalia pads the panel by 14. Everything sits GRID further in, on the
-- same 24 px edge as the Pond panels that open in this top-right slot: the
-- head and its hairline, and the rows column with its tiles, tracks, section
-- labels, toggle and slider rows, captions and notes, so a tile's edge lines
-- up with the hairline over it (the battery panel's profile tiles do the
-- same). Only the nav row's hover cells fill the content box, as Pond's hover
-- pills do. The rows column carries the inset, so rows inside it take
-- TEXT_PAD = 0 (views still pass it, in case a row needs its own inset).
local GRID = 10
local CONTENT_W = 316 - 28 -- plugin.toml width minus Noctalia's padding

-- ui.scroll insets its viewport by a fixed 4 px left/right and 8 px top/bottom
-- in surface pixels (not scaled by ui_scale), so the column inside the
-- scroll takes GRID less that inset, and the plain column the same top and
-- bottom inset: nothing shifts between the two.
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
local TEXT_PAD = 0 -- a text row inside the rows column: already on the edge

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
-- Pond's orange instead. Captions and notes are the one 12 px text; every
-- other label is the 13 px body of the Pond panels.
local function captionText(text, color, grow)
  if color == "tertiary" then color = ATTENTION end
  return ui.label({ text = text, fontSize = 12, color = color or "on_surface/0.5", maxLines = 3, flexGrow = grow and 1 or nil })
end

-- A caption in a row of its own sits on the text edge (TEXT_PAD); one that
-- trails a track (the Awake row's time left) keeps the same inset on its
-- right, so it ends on the right text edge.
local function caption(text, color)
  return ui.row({ paddingH = TEXT_PAD, align = "center" }, { captionText(text, color, true) })
end

-- Sub-view section label, with optional trailing detail or node.
local function label(title, trailing)
  local kids = { ui.label({ text = title, fontSize = 13, fontWeight = "medium", color = "on_surface/0.5", flexGrow = 1 }) }
  if type(trailing) == "string" and trailing ~= "" then
    kids[#kids + 1] = captionText(trailing)
  elseif type(trailing) == "table" then
    kids[#kids + 1] = trailing
  end
  return ui.row({ align = "center", gap = 8, height = 18, paddingH = TEXT_PAD }, kids)
end

-- Onest Medium runs about 7 units a character at 13. A row whose longest
-- label would touch its slab's edges at 13 drops to 12 (Breathe in the 5-up
-- effect track); a slot is the row's width shared out, a track counted at
-- its narrowest (beside an iconRow glyph).
local function fitSize(options, slotW, margin)
  local longest = 0
  for _, o in ipairs(options) do
    local n = utf8.len(o.label or "") or #(o.label or "")
    if n > longest then longest = n end
  end
  return (longest * 7 + margin <= slotW) and 13 or 12
end

local function tile(section, opt, selected, size)
  local key = section .. ":" .. opt.id
  local active = opt.id == selected
  local enabled = opt.enabled ~= false and not busy[section]
  local hovered = not active and enabled and hover == key
  -- The picked tile takes one accent throughout, like Pond's selected power
  -- profile: the accent at ~15% for the fill, a hairline and the icon in the
  -- accent itself. Its own tint (#rrggbb: Pond's profile colours on the
  -- Performance tiles) or lavender. The rest stay white at 60%.
  local onFill, onBorder, onGlyph = FILL_ON, LINE_ON, "primary"
  if opt.tint then onFill, onBorder, onGlyph = opt.tint .. "26", opt.tint .. "66", opt.tint end -- 15% / 40%
  local fill = active and onFill or (hovered and FILL_HOVER or FILL_IDLE)
  local glyphColor = active and onGlyph or (hovered and "on_surface" or "on_surface/0.6")
  -- opt.icon: one of Pond's profile icons (assets/<icon>.svg white, and
  -- <icon>-active.svg in its own hue), at Pond's 60% / 100% like its glyphs
  local icon
  if opt.icon then
    icon = ui.image({ key = key .. ":icon", path = ASSETS .. opt.icon .. (active and "-active" or "") .. ".svg",
      width = 20, height = 20, fit = "contain", opacity = (active or hovered) and 1 or 0.6 })
  else
    icon = ui.glyph({ name = opt.glyph, size = 19, color = glyphColor })
  end
  return ui.column({
    key = key, flexGrow = 1, gap = 4, paddingV = 10, radius = R_TILE, fill = fill, align = "center",
    border = active and onBorder or FILL_NONE, borderWidth = 1,
    opacity = (opt.enabled == false) and 0.35 or 1,
    onClick = enabled and not active and opt.onClick or nil,
    onHover = hoverHandler(key),
  }, {
    icon,
    ui.label({ text = opt.label, fontSize = size or 13, fontWeight = "medium", color = ink(active, hovered, "on_surface/0.7"), maxLines = 1 }),
  })
end

local function segment(section, opt, selected, size)
  local key = section .. ":" .. opt.id
  local active = opt.id == selected
  local enabled = opt.enabled ~= false and not busy[section]
  local hovered = not active and enabled and hover == key
  local fill = active and FILL_ON or (hovered and FILL_HOVER or FILL_NONE)
  -- The picked segment matches the picked tile and chip: the accent at 15%
  -- with a 40% hairline. Every segment carries the 1 px border (invisible when
  -- not picked) so picking one never shifts the track. 7 px corners sit
  -- concentric in the track's 10 (less its 3 px padding).
  return ui.row({
    key = key, flexGrow = 1, height = 30, radius = 7, fill = fill, justify = "center", align = "center",
    border = active and LINE_ON or FILL_NONE, borderWidth = 1,
    opacity = (opt.enabled == false) and 0.35 or 1,
    onClick = enabled and not active and opt.onClick or nil,
    onHover = hoverHandler(key),
  }, {
    ui.label({ text = opt.label, fontSize = size or 13, fontWeight = "medium", color = ink(active, hovered, "on_surface/0.6"), maxLines = 1 }),
  })
end

-- Tiles share the rows column's width (gap 6); a track is 36 tall like
-- toggleRow, its 30 px segments centred in 3 px padding.
local ROWS_W = CONTENT_W - 2 * GRID
local function choices(kind, section, options, selected, fixedSize)
  local n = math.max(1, #options)
  local size = fixedSize
  if size then -- the caller measured it
  elseif kind == "tile" then
    size = fitSize(options, (ROWS_W - 6 * (n - 1)) / n, 16)
  else
    size = fitSize(options, (ROWS_W - 30 - 6 - 2 * (n - 1)) / n, 10)
  end
  local children = {}
  for _, o in ipairs(options) do
    children[#children + 1] = (kind == "tile" and tile or segment)(section, o, selected, size)
  end
  if kind == "tile" then return ui.row({ gap = 6 }, children) end
  return ui.row({ gap = 2, padding = 3, height = 36, radius = 10, fill = FILL_IDLE, align = "center" }, children)
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
    ui.label({ text = text, fontSize = 13, fontWeight = "medium", color = color, maxLines = 1 }),
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
  return ui.row({ align = "center", gap = 8, paddingH = TEXT_PAD }, children)
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

local function hairline(key)
  return ui.row({ key = key, height = 1, fill = HAIRLINE }, { ui.spacer({ flexGrow = 1 }) })
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

-- ── main view ─────────────────────────────────────────────────────────────────

-- The one expressive element: a live trace of power draw on battery, sampled
-- every 10 s by the bar widget, so a dGPU waking up shows as a step you can
-- see. The battery only measures draw while discharging, so on AC there is
-- no trace and no filler line in its place: the header just gets shorter.
local function onBattery() return st.battery_status == "Discharging" end

local function drawTrace()
  if not onBattery() then return nil end
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

-- The state word beside the figure, worded as pond-panels' battery panel
-- says it (stateText there), so the two never disagree: "Charged" held at
-- the charge limit, "Plugged in" below it, "Charging", "On battery".
-- Lime (Pond's success) only while power is going in or the battery is full.
local function stateText()
  local s = st.battery_status
  if s == "Charging" then return "Charging", LIME end
  if s == "Discharging" then return "On battery", "on_surface/0.5" end
  if s == "Full" then return "Charged", LIME end
  if s == "Not charging" then
    local pct, limit = num(st.battery), num(st.limit)
    if not limit or (pct and pct >= limit - 2) then return "Charged", LIME end
    return "Plugged in", "on_surface/0.5"
  end
  if st.ac == "1" then return "Plugged in", "on_surface/0.5" end
  return "", "on_surface/0.5"
end

-- The panel's head (no title over it: the serif battery figure is the
-- headline, the way Pond's battery panel leads with its number), over the
-- hairline every Pond panel draws under its title. The battery's rate is the
-- machine's draw only while discharging, written like Pond's battery panel
-- ("12 W" at 70%). Charging, it is the charge rate ("+45 W", lime like the
-- state word beside it); on AC otherwise, nothing.
local function header()
  local w = math.abs(num(st.battery_watts) or 0)
  local status = st.battery_status
  local word, wordColor = stateText()
  local rate = nil
  if status == "Discharging" then
    rate = ui.label({ text = string.format("%.0f W", w), fontSize = 13, fontFamily = MONO, color = "on_surface/0.7" })
  elseif status == "Charging" and w > 0 then
    rate = ui.label({ text = string.format("+%.0f W", w), fontSize = 13, fontFamily = MONO, color = LIME })
  end
  return ui.column({ key = "head", gap = 6, paddingH = GRID }, packed(
    ui.row({ align = "end", gap = 8 }, {
      -- Pond's big numbers are its serif display face
      ui.label({ text = st.battery and `{st.battery}%` or "", fontFamily = TITLE_FONT, fontSize = 30, color = "on_surface" }),
      -- paddingV 7 lifts the small text onto the serif number's baseline
      -- (bottom-aligned boxes left it 7 units low: the serif's descent)
      ui.row({ flexGrow = 1, paddingV = 7, gap = 8, align = "end" }, {
        ui.label({ text = word, fontSize = 13, fontWeight = "medium", color = wordColor, flexGrow = 1, maxLines = 1 }),
        rate,
      }),
    }),
    drawTrace(),
    ui.row({ align = "center", gap = 12 }, {
      st.cpu_temp and stat("temperature", "CPU", nil, `{st.cpu_temp}°`) or ui.spacer({}),
      ui.spacer({ flexGrow = 1 }),
      stat("device-desktop", dgpuText(), dgpuActive() and ATTENTION or nil),
    }),
    hairline("title:line")
  ))
end

local function perfSection()
  local sel = picked.perf or st.perf
  local function pick(id) return function() act("perf", id, { "perf", id }) end end
  return section({
    choices("tile", "perf", {
      -- Pond's power profiles, icons and hues (its battery panel names them
      -- the same: Silent / Balanced / Turbo on this machine)
      { id = "silent", label = "Silent", icon = "eco", tint = LIME, onClick = pick("silent") },
      { id = "balanced", label = "Balanced", icon = "balanced", tint = PINK, onClick = pick("balanced") },
      { id = "turbo", label = "Turbo", icon = "performance", tint = YELLOW, onClick = pick("turbo") },
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

  -- A track like the four rows under it, in the plain lavender pick: lime
  -- stays the power profile's alone (the Silent tile above, the battery
  -- panel, the desktop card). Four G-Helper names did not fit a track beside
  -- the glyph, so two take shorter ones: Standard is asusctl's own "Hybrid",
  -- and Optimized (Eco on battery, Hybrid plugged in) is "Auto" like the
  -- Screen row's power-following refresh rate. "Ultimate" is mostly narrow
  -- letters (about 51 units at 13, against Medium's 47 on the keyboard
  -- track), so it keeps the 13 every other track uses, though fitSize's
  -- 7-a-character estimate would drop the row to 12.
  local opts = {}
  if canOff then
    opts[#opts + 1] = { id = "eco", label = "Eco", enabled = not ult, onClick = pick("eco") }
  end
  opts[#opts + 1] = { id = "standard", label = "Hybrid", onClick = pick("standard") }
  if canOff then
    opts[#opts + 1] = { id = "optimized", label = "Auto", enabled = not ult, onClick = pick("optimized") }
  end
  if canMux then
    opts[#opts + 1] = { id = "ultimate", label = "Ultimate", onClick = pick("ultimate") }
  end
  return section({ iconRow("device-desktop", choices("segment", "gpu", opts, sel, 13)), noteRow("gpu", restart) })
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
  -- The one-shot full charge lives in the Power view: a trailing button
  -- here cut this track 50 units short of the others' right edge.
  return section({
    iconRow("battery-2", choices("segment", "limit", opts, sel)),
    noteRow("limit"),
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
  -- glyph over label in four equal cells: side by side at 13, "Lighting"
  -- overran its quarter and the gaps between the labels came out uneven
  return ui.column({
    key = key, flexGrow = 1, gap = 4, height = 52, radius = 12,
    fill = hover == key and FILL_HOVER or FILL_NONE, justify = "center", align = "center",
    onClick = function()
      view = id
      hover = ""
      if id == "sleep" then Awake.refresh() else refreshExtra() end
      render()
    end,
    onHover = hoverHandler(key),
  }, {
    ui.glyph({ name = glyph, size = 18, color = color }),
    ui.label({ text = text, fontSize = 12, fontWeight = "medium", color = color, maxLines = 1 }),
  })
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
  return ui.column({ key = key, gap = 12, paddingH = GRID }, {
    ui.row({ height = 32, align = "center", gap = 10 }, kids),
    hairline(key .. ":line"),
  })
end

-- No title: "Laptop" said nothing the battery figure doesn't, and cost a
-- 60-unit band. header() is the head, the nav row the foot. Power takes the
-- tuning sliders' glyph (the gauge is Turbo's icon now); the Awake view keeps
-- the id "sleep" (IPC: panel-open ishaan/rog-helper:panel sleep), since
-- "Sleep" elsewhere means suspend (the Apple menu, the session sheet).
local function mainView()
  return {
    header(),
    perfSection(),
    ui.column({ gap = 8 }, packed(gpuSection(), screenSection(), batterySection(), keyboardSection(), Awake.mainRow(), noteRow("awake_quick"))),
    ui.column({ gap = 8 }, {
      -- inset like the head's hairline: both span the text column
      ui.column({ key = "nav:linebox", paddingH = GRID }, { hairline("nav:line") }),
      ui.row({ gap = 4 }, {
        navButton("power", "adjustments-horizontal", "Power"),
        navButton("fans", "propeller", "Fans"),
        navButton("lighting", "bulb", "Lighting"),
        navButton("sleep", "coffee", "Awake"),
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

-- Pond's toggle (Toggle.qml): a 54x28 outlined pill with faint off/on
-- markers; the knob is red with a dash when off and green with a bar when on
-- (Pond's literals), and it rolls: over 200 ms on Pond's ease
-- (cubic-bezier 0.77, 0, 0.175, 1) it slides the 26 px across, its colours
-- cross-fade, and the dash turns into the bar once the knob has rolled a
-- quarter turn (Pond rotates the knob for its last 12 x pi/2 = 18.85 px of
-- travel; here the mark's width and height trade places over that stretch).
-- The UI tree has no overlays, so the knob moves between two spacers and the
-- faint markers (Pond's stationary outlines) only show while it rests. A
-- render while any knob is moving asks for frame ticks; idle, none.
-- The whole row is the click target; onChange gets "true"/"false" like
-- ui.toggle's.
local TOGGLE_MS = 200
local TRAVEL = 26          -- 54 - 24 knob - 2 x 2 padding
local ROLL_FROM = TRAVEL - 12 * math.pi / 2 -- 7.15: where the quarter turn starts
local toggleAnims = {}     -- toggle key -> { from, to, t0 } (position 0..1)
local toggleMoving = false -- set by any knob still moving in this render
local frameTickOn = false

-- Pond's easing curve, x(t) solved for t by Newton's method, then y(t).
local function bezier(u)
  if u <= 0 then return 0 elseif u >= 1 then return 1 end
  local x1, y1, x2, y2 = 0.77, 0, 0.175, 1
  local function at(t, a, b) return 3 * (1 - t) ^ 2 * t * a + 3 * (1 - t) * t * t * b + t ^ 3 end
  local function slope(t, a, b) return 3 * (1 - t) ^ 2 * a + 6 * (1 - t) * t * (b - a) + 3 * t * t * (1 - b) end
  local t = u
  for _ = 1, 8 do
    local d = slope(t, x1, x2)
    if math.abs(d) < 1e-6 then break end
    t = math.clamp(t - (at(t, x1, x2) - u) / d, 0, 1)
  end
  return at(t, y1, y2)
end

local function hexLerp(a, b, p)
  local out = "#"
  for i = 2, 6, 2 do
    local x, y = tonumber(a:sub(i, i + 1), 16), tonumber(b:sub(i, i + 1), 16)
    out ..= string.format("%02x", math.floor(x + (y - x) * p + 0.5))
  end
  return out
end

-- The knob's position (0 off .. 1 on) for this render, and whether it moves.
local function togglePosition(key, on)
  local target = on and 1 or 0
  local now = noctalia.nowMs()
  local a = toggleAnims[key]
  local function at(anim)
    local u = (now - anim.t0) / TOGGLE_MS
    if u >= 1 then return anim.to, false end
    return anim.from + (anim.to - anim.from) * bezier(u), true
  end
  if not a then
    a = { from = target, to = target, t0 = 0 }
    toggleAnims[key] = a
  elseif a.to ~= target then
    local p = at(a) -- turn back from wherever the knob is now
    a.from, a.to, a.t0 = p, target, now
  end
  local p, moving = at(a)
  if moving then toggleMoving = true end
  return p, moving
end

local function pondToggle(key, on, hovered)
  local p, moving = togglePosition(key, on)
  local q = math.clamp((TRAVEL * p - ROLL_FROM) / (TRAVEL - ROLL_FROM), 0, 1)
  local knob = ui.column({ key = key .. ":knob", width = 24, height = 24, radius = 12, align = "center", justify = "center",
    fill = hexLerp("#613129", "#0c3723", p) }, {
    ui.box({ key = key .. ":mark", width = 12 - 8 * q, height = 4 + 8 * q, radius = 2, fill = hexLerp("#fb9b89", "#b0ff4f", p) }),
  })
  -- Pond's outlines sit centred on the knob's two resting places
  local function ghost(w, h)
    return ui.row({ width = 24, height = 24, align = "center", justify = "center" }, {
      ui.box({ width = w, height = h, radius = 2.5, fill = FILL_NONE, border = "#e7e7e74d", borderWidth = 1 }),
    })
  end
  local left, right = {}, {}
  if not moving and p >= 1 then left = { ghost(13, 5), ui.spacer({ width = 2, flexGrow = 0 }) } end
  if not moving and p <= 0 then right = { ui.spacer({ width = 2, flexGrow = 0 }), ghost(5, 13) } end
  return ui.row({
    key = key .. ":pill", width = 54, height = 28, radius = 14, padding = 2, gap = 0, align = "center",
    fill = hovered and FILL_HOVER or FILL_NONE, border = HAIRLINE, borderWidth = 1,
  }, {
    ui.row({ key = key .. ":before", width = TRAVEL * p, height = 24, gap = 0, align = "center" }, left),
    knob,
    ui.row({ key = key .. ":after", width = TRAVEL * (1 - p), height = 24, gap = 0, align = "center" }, right),
  })
end

-- Label on the text edge, toggle on the right text edge (Pond's rows).
local function toggleRow(title, checked, onChange, detail)
  local key = "toggle:" .. title
  local hovered = hover == key
  local kids = { ui.label({ text = title, fontSize = 13, fontWeight = "medium", color = "on_surface", flexGrow = 1, maxLines = 1 }) }
  if detail then kids[#kids + 1] = captionText(detail) end
  kids[#kids + 1] = pondToggle(key, checked, hovered)
  return ui.row({
    key = key, align = "center", gap = 8, height = 36, radius = 12, paddingH = TEXT_PAD,
    onClick = function() onChange(checked and "false" or "true") end,
    onHover = hoverHandler(key),
  }, kids)
end

-- The Awake view and the main-view Awake row are drawn by awake_view.luau from
-- these blocks; mainView only calls into it at render time, so it can be set
-- up here, once subHeader and toggleRow exist.
Awake.setup({
  choices = choices, iconRow = iconRow, label = label, section = section, toggleRow = toggleRow,
  subHeader = subHeader, caption = caption, noteRow = noteRow, packed = packed,
  picked = picked, bin = AWAKECTL, TEXT_PAD = TEXT_PAD,
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
  R_TILE = R_TILE, FILL_IDLE = FILL_IDLE, PERF_LABEL = PERF_LABEL, TEXT_PAD = TEXT_PAD,
  num = num, has = has, picked = picked, busy = busy,
  hover = function() return hover end,
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
-- and grows down from the top-right corner it is pinned to, so there is no
-- empty strip under the nav row when no note or Restart row shows. A ui.scroll
-- has no natural height of its own, so the main view's rows only go in one
-- when they would run past the card's maximum; then a fixed-height column
-- holds it, header and nav row staying put. The sub-views hug their rows the
-- same way (estH below); one too long for the card (Awake) takes a fixed 592
-- card and scrolls, while the main view may grow to 680 while notes show.
-- 680 lets the Awake view (about 570 of rows) hug too, with some to spare.
local MAX_H = 680    -- plugin.toml max_height
local SUB_H = 592    -- the sub-views' card
local PANEL_PAD = 14 -- Noctalia's padding on each side of the content
local ROOT_GAP = 14  -- between the header, the rows and the nav row
-- a little over the real heights (Onest's line is 1.275 em, the serif's 1.3):
-- sub-view title = 32 row + 12 + hairline; nav = hairline + 8 + 52 cell;
-- dry-run caption = one 12 px line + the gap
local SUB_HEAD_H, FOOT_H, DRY_H = 46, 62, 30
-- the main view's head, header(): the serif figure's 39 line, the stat row
-- (16) and the hairline, 6 apart, plus the 30 px trace and its gap on battery
local function mainHeadH()
  return 39 + 6 + 16 + 6 + 1 + (onBattery() and (30 + 6) or 0) + 2
end
-- main-view rows with every section present and no notes: the 61 tile row
-- (10 + 20 icon + 4 + 17 label + 10), five 36 tracks 8 apart, and the 14
-- between the two: 61 + 212 + 14 = 287
local MAIN_ROWS_H = 289
local NOTE_LINE = 16 -- one 12 px line
local NOTE_CHARS = 36 -- about a line of 12 px text at the text edges
local RESTART_H = 14 -- the Restart button over its note's one line

-- Estimated natural height of the main view's rows: the base plus whatever
-- notes and the Restart row add right now (an over-estimate only switches to
-- the scrolling layout a little early).
local function mainRowsHeight()
  local h = MAIN_ROWS_H + 2 * SCROLL_PAD_V
  local now = noctalia.nowMs()
  for _, n in pairs(notes) do
    if not (n.expires and now > n.expires) then
      h += 8 + NOTE_LINE * (#(n.text or "") > NOTE_CHARS and 2 or 1)
    end
  end
  if needsRestart() then h += RESTART_H end
  return h
end

-- Rough natural height of a sub-view's rows, read off the ui tree itself
-- (plain tables): explicit heights where given, a label's lines at 1.3 em,
-- small controls at Noctalia's 32 control height, gaps and padding summed
-- down a column and maxed across a row. It errs high, which only means a
-- view near the limit scrolls a little early; a short view (Fans, Lighting)
-- then hugs its rows instead of leaving the 592 card half empty.
local LINE_EM = 1.3
local function estH(node)
  if type(node) ~= "table" then return 0 end
  local p = node.props or {}
  if p.visible == false then return 0 end
  local t = node.type
  local padV = p.paddingV or p.padding or 0
  local h
  if p.height then
    h = p.height
  elseif t == "label" then
    local size = p.fontSize or 13
    local lines = 1
    if (p.maxLines or 1) > 1 then
      local perLine = math.max(1, math.floor((p.maxWidth or (ROWS_W - 2 * TEXT_PAD)) / (size * 0.56)))
      lines = math.min(p.maxLines, math.ceil((utf8.len(p.text or "") or 0) / perLine))
    end
    h = size * LINE_EM * math.max(1, lines)
  elseif t == "glyph" then
    h = p.size or 16
  elseif t == "button" or t == "select" or t == "slider" or t == "toggle" or t == "input" then
    h = p.controlSize == "sm" and 32 or 38
  elseif t == "separator" then
    h = 1
  elseif t == "row" or t == "column" or t == "scroll" then
    local kids, sum, most, n = node.children or {}, 0, 0, 0
    for _, k in ipairs(kids) do
      local kh = estH(k)
      if kh > 0 or t == "row" then n += 1 end
      sum += kh
      if kh > most then most = kh end
    end
    if t == "row" then h = most else h = sum + (p.gap or 0) * math.max(0, n - 1) end
    h += 2 * padV
  else
    h = 0
  end
  if p.minHeight and p.minHeight > h then h = p.minHeight end
  return h
end

render = function()
  toggleMoving = false
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
  local dry = noctalia.getConfig("dry_run") == true
    and ui.row({ key = "dry", paddingH = GRID }, { captionText("Dry run: buttons only show their commands", ATTENTION, true) }) or nil

  local headH = view == "main" and mainHeadH() or SUB_HEAD_H
  local room = MAX_H - 2 * PANEL_PAD - headH - ROOT_GAP
  if foot then room -= (FOOT_H + ROOT_GAP) end
  if dry then room -= DRY_H end
  local rows = nil
  if #items > 0 then
    local natural
    if view == "main" then
      natural = mainRowsHeight()
    else
      natural = estH(ui.column({ gap = 14 }, items)) + 2 * SCROLL_PAD_V
    end
    if natural <= room then
      rows = ui.column({ key = "rows:plain", gap = 14, paddingH = GRID, paddingV = SCROLL_PAD_V }, items)
    else
      -- too long to hug: the main view fills its maximum, a sub-view the
      -- shorter fixed card, and the rows scroll
      if view ~= "main" then room -= MAX_H - SUB_H end
      rows = ui.column({ key = "rows:box", height = room }, {
        ui.scroll({ key = "rows:scroll", flexGrow = 1 }, {
          ui.column({ key = "rows:inset", gap = 14, paddingH = GRID - SCROLL_PAD_H }, items),
        }),
      })
    end
  end
  local kids = packed(dry, head, rows, foot)
  -- keyed by view (and Lighting's tab) so retained nodes never carry props
  -- across them: the Slash tab's chip row kept the Keyboard tab's track fill
  local viewKey = "view:" .. view .. (view == "lighting" and (":" .. Lighting.tab()) or "")
  panel.render(ui.column({ gap = ROOT_GAP }, { ui.column({ key = viewKey, gap = ROOT_GAP }, kids) }))
  -- frame ticks only while a toggle's knob is rolling
  if toggleMoving ~= frameTickOn then
    frameTickOn = toggleMoving
    panel.setNeedsFrameTick(toggleMoving)
  end
end

function onFrameTick(_deltaMs)
  if isOpen then render() end
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
  toggleAnims = {} -- a switch flipped while closed shows its new side, no roll
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
  if frameTickOn then
    frameTickOn = false
    panel.setNeedsFrameTick(false)
  end
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
