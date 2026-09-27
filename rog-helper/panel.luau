--!nonstrict
-- ROG helper panel: G-Helper's one-glance layout in Noctalia's M3 surfaces.
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
--   tiles  - the big mode switches (Performance, GPU): separate slabs, styled
--            like the Control Center's tiles.
--   tracks - every smaller choice: one pill track, the active option a
--            primary pill inside it, the rest bare text.
-- Labels are dropped wherever an icon or the options themselves say enough.
--
-- Theme roles only, the ones Noctalia's own panels use, so the panel follows
-- the palette and sits on the shell's panel background: an active choice is
-- primary with on_primary content, everything else surface_variant, and a
-- hovered one hover with on_hover content.

local R_TILE = 16
local FILL_IDLE = "surface_variant" -- inactive tiles, tracks, chips, cards
local FILL_HOVER = "hover"
local FILL_ON = "primary"

-- Content colour on a fill: on_primary on an active choice, on_hover on a
-- hovered one, otherwise `idle`.
local function ink(active, hovered, idle)
  if active then return "on_primary" end
  if hovered then return "on_hover" end
  return idle
end

local function hoverHandler(state, key)
  if state == "true" then hover = key elseif hover == key then hover = "" end
  render()
end

local function caption(text, color)
  return ui.label({ text = text, fontSize = 11, color = color or "on_surface_variant" })
end

-- Sub-view section label, with optional trailing detail or node.
local function label(title, trailing)
  local kids = { ui.label({ text = title, fontSize = 12, color = "on_surface_variant", flexGrow = 1 }) }
  if type(trailing) == "string" and trailing ~= "" then
    kids[#kids + 1] = caption(trailing)
  elseif type(trailing) == "table" then
    kids[#kids + 1] = trailing
  end
  return ui.row({ align = "center", gap = 8, height = 16 }, kids)
end

local function tile(section, opt, selected)
  local key = section .. ":" .. opt.id
  local active = opt.id == selected
  local enabled = opt.enabled ~= false and not busy[section]
  local hovered = not active and enabled and hover == key
  local fill = active and FILL_ON or (hovered and FILL_HOVER or FILL_IDLE)
  local color = ink(active, hovered, "on_surface")
  return ui.column({
    key = key, flexGrow = 1, gap = 3, paddingV = 9, radius = R_TILE, fill = fill, align = "center",
    opacity = (opt.enabled == false) and 0.35 or 1,
    onClick = enabled and not active and opt.onClick or nil,
    onHover = hoverHandler,
  }, {
    ui.glyph({ name = opt.glyph, size = 19, color = color }),
    ui.label({ text = opt.label, fontSize = 12, color = color }),
  })
end

local function segment(section, opt, selected)
  local key = section .. ":" .. opt.id
  local active = opt.id == selected
  local enabled = opt.enabled ~= false and not busy[section]
  local hovered = not active and enabled and hover == key
  local fill = active and FILL_ON or (hovered and FILL_HOVER or nil)
  return ui.row({
    key = key, flexGrow = 1, paddingV = 6, radius = 99, fill = fill, justify = "center", align = "center",
    opacity = (opt.enabled == false) and 0.35 or 1,
    onClick = enabled and not active and opt.onClick or nil,
    onHover = hoverHandler,
  }, {
    ui.label({ text = opt.label, fontSize = 12, color = ink(active, hovered, "on_surface_variant") }),
  })
end

local function choices(kind, section, options, selected)
  local children = {}
  for _, o in ipairs(options) do
    children[#children + 1] = (kind == "tile" and tile or segment)(section, o, selected)
  end
  if kind == "tile" then return ui.row({ gap = 6 }, children) end
  return ui.row({ gap = 2, padding = 3, radius = 99, fill = FILL_IDLE }, children)
end

-- A settings row whose leading glyph stands in for its label.
local function iconRow(glyph, control, trailing)
  local kids = {
    ui.column({ width = 22, align = "center" }, { ui.glyph({ name = glyph, size = 16, color = "on_surface_variant" }) }),
    ui.column({ flexGrow = 1 }, { control }),
  }
  if trailing then kids[#kids + 1] = trailing end
  return ui.row({ align = "center", gap = 8 }, kids)
end

-- Pill that toggles on its own (used for multi-select flags).
local function chip(key, text, on, onClick)
  local hovered = not on and hover == key
  local fill = on and FILL_ON or (hovered and FILL_HOVER or FILL_IDLE)
  local color = ink(on, hovered, "on_surface_variant")
  local kids = {}
  if on then kids[#kids + 1] = ui.glyph({ name = "check", size = 13, color = color }) end
  kids[#kids + 1] = ui.label({ text = text, fontSize = 12, color = color })
  return ui.row({ key = key, gap = 4, paddingH = 9, paddingV = 6, radius = 99, fill = fill, align = "center", onClick = onClick, onHover = hoverHandler }, kids)
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
      text = n.text, fontSize = 11, maxLines = 2, flexGrow = 1,
      color = n.tone == "error" and "error" or "on_surface_variant",
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

local function stat(glyph, text, color)
  return ui.row({ gap = 4, align = "center" }, {
    ui.glyph({ name = glyph, size = 13, color = color or "on_surface_variant" }),
    ui.label({ text = text, fontSize = 11, color = color or "on_surface_variant" }),
  })
end

-- ── main view ─────────────────────────────────────────────────────────────────

-- The one expressive element: a live trace of power draw on battery, sampled
-- every 10 s by the bar widget, so a dGPU waking up shows as a step you can
-- see. The battery only measures draw while discharging, so on AC the trace
-- gives way to a caption of the same height.
local function drawTrace()
  if st.battery_status ~= "Discharging" then
    return ui.column({ height = 30, justify = "center", align = "center" }, { caption("Power draw shows on battery") })
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
    color = dgpuActive() and "tertiary" or "primary", color2 = "primary/0", lineWidth = 1.5, fillOpacity = 0.14 })
end

-- The battery's rate is the machine's draw only while discharging. Charging,
-- it is the charge rate (shown muted, not as usage); on AC otherwise, nothing.
local function header()
  local w = math.abs(num(st.battery_watts) or 0)
  local status = st.battery_status
  local rate = nil
  if status == "Discharging" then
    rate = ui.label({ text = string.format("%.1f W", w), fontSize = 13, fontWeight = "medium", color = "primary" })
  elseif status == "Charging" and w > 0 then
    rate = ui.label({ text = string.format("Charging +%.0f W", w), fontSize = 11, color = "on_surface_variant" })
  end
  return ui.column({ gap = 6 }, {
    ui.row({ align = "end", gap = 8 }, {
      ui.label({ text = st.battery and `{st.battery}%` or "", fontSize = 20, fontWeight = "light", color = "on_surface" }),
      ui.label({ text = chargerText() or "On battery", fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
      rate,
    }),
    drawTrace(),
    ui.row({ align = "center", gap = 12 }, {
      st.cpu_temp and stat("temperature", `CPU {st.cpu_temp}°`) or ui.spacer({}),
      ui.spacer({ flexGrow = 1 }),
      stat("device-desktop", dgpuText(), dgpuActive() and "tertiary" or nil),
    }),
  })
end

local function perfSection()
  local sel = picked.perf or st.perf
  local function pick(id) return function() act("perf", id, { "perf", id }) end end
  return section({
    choices("tile", "perf", {
      { id = "silent", label = "Silent", glyph = "feather", onClick = pick("silent") },
      { id = "balanced", label = "Balanced", glyph = "scale", onClick = pick("balanced") },
      { id = "turbo", label = "Turbo", glyph = "rocket", onClick = pick("turbo") },
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
    opts[#opts + 1] = { id = "eco", label = "Eco", glyph = "leaf", enabled = not ult, onClick = pick("eco") }
  end
  opts[#opts + 1] = { id = "standard", label = "Standard", glyph = "device-laptop", onClick = pick("standard") }
  if canOff then
    opts[#opts + 1] = { id = "optimized", label = "Optimized", glyph = "sparkles", enabled = not ult, onClick = pick("optimized") }
  end
  if canMux then
    opts[#opts + 1] = { id = "ultimate", label = "Ultimate", glyph = "bolt", onClick = pick("ultimate") }
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
  local color = ink(false, hover == key, "on_surface_variant")
  return ui.row({
    key = key, flexGrow = 1, gap = 6, paddingV = 7, radius = 99,
    fill = hover == key and FILL_HOVER or nil, justify = "center", align = "center",
    onClick = function()
      view = id
      hover = ""
      if id == "sleep" then Awake.refresh() else refreshExtra() end
      render()
    end,
    onHover = hoverHandler,
  }, {
    ui.glyph({ name = glyph, size = 15, color = color }),
    ui.label({ text = text, fontSize = 12, color = color }),
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
    header(),
    ui.column({ gap = 8 }, packed(perfSection(), gpuSection())),
    ui.column({ gap = 8 }, packed(screenSection(), batterySection(), keyboardSection(), Awake.mainRow(), noteRow("awake_quick"))),
    ui.row({ gap = 4 }, {
      navButton("power", "gauge", "Power"),
      navButton("fans", "propeller", "Fans"),
      navButton("lighting", "bulb", "Lighting"),
      navButton("sleep", "moon", "Sleep"),
    }),
  }
end

-- ── sub-view chrome ───────────────────────────────────────────────────────────

local function subHeader(title, detail)
  return ui.row({ align = "center", gap = 6 }, {
    ui.button({ glyph = "chevron-left", variant = "ghost", controlSize = "sm", onClick = function()
      view = "main"
      hover = ""
      render()
    end }),
    ui.label({ text = title, fontSize = 14, fontWeight = "semibold", color = "on_surface", flexGrow = 1 }),
    caption(detail or ""),
  })
end

local function toggleRow(title, checked, onChange, detail)
  local kids = { ui.label({ text = title, fontSize = 12, color = "on_surface", flexGrow = 1 }) }
  if detail then kids[#kids + 1] = caption(detail) end
  kids[#kids + 1] = ui.toggle({ checked = checked, onChange = onChange })
  return ui.row({ align = "center", gap = 8 }, kids)
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

-- The panel has a fixed height (plugin.toml) and clips whatever doesn't fit,
-- and rows come and go (notes, Restart, the Awake row, With monitor). So every
-- view keeps its header, and the main view its Power/Fans/Lighting/Sleep row,
-- in place and scrolls the rest when it runs taller than the panel.
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
  local dry = noctalia.getConfig("dry_run") == true and caption("Dry run: buttons only show their commands", "tertiary") or nil
  local kids = packed(dry, head, #items > 0 and ui.scroll({ flexGrow = 1, gap = 14 }, items) or nil, foot)
  -- keyed by view so retained nodes never carry props across views
  panel.render(ui.column({ flexGrow = 1, gap = 14 }, { ui.column({ key = "view:" .. view, flexGrow = 1, gap = 14 }, kids) }))
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
