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
local Awake = require("./awake_view.luau")
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
local powerMode = nil -- which mode's CPU limits are being edited
local drafts = {} -- mode -> { pl1, pl2 } while editing
local fanProfile = nil -- balanced | performance
local lightTab = "keyboard" -- keyboard | slash
local themeHex = nil

-- ── helpers ───────────────────────────────────────────────────────────────────

local function num(v) return tonumber(v or "") end

-- Capability flag from rogctl ("has_*"). Unknown until the first snapshot,
-- which counts as present so nothing flickers away on open.
local function has(t, key) return t["has_" .. key] ~= "0" end

local function parse(out)
  local t = {}
  for line in (out or ""):gmatch("[^\n]+") do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k then t[k] = v end
  end
  return t
end

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

-- Theme primary as RRGGBB, from the palette Noctalia writes for Hyprland.
local function readThemeHex()
  local s = noctalia.readFile("~/.config/hypr/noctalia.lua") or ""
  local hex = s:match('local primary = "rgb%((%x%x%x%x%x%x)%)"')
  if not hex then
    local css = noctalia.readFile("~/.config/gtk-4.0/noctalia.css") or ""
    hex = css:match("@define%-color accent_color #(%x%x%x%x%x%x)") or css:match("primary[^#]*#(%x%x%x%x%x%x)")
  end
  return hex and hex:lower() or nil
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
    local cmds = {}
    for line in (res.stderr or ""):gmatch("[^\n]+") do
      local c = line:match("^dry%-run: (.*)$")
      if c then cmds[#cmds + 1] = c end
    end
    if dry or #cmds > 0 then
      noctalia.notify("ROG helper dry run", #cmds > 0 and table.concat(cmds, "\n") or "Nothing to do")
    end
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
--   tiles  - the big mode switches (Performance, GPU): separate soft slabs,
--            the active one washed in primary with a primary glyph.
--   tracks - every smaller choice: one faint pill track, the active option a
--            primary pill inside it, the rest bare text.
-- Labels are dropped wherever an icon or the options themselves say enough.

local R_TILE = 16
local FILL_TILE = "on_surface/0.05"
local FILL_TRACK = "on_surface/0.05"
local FILL_HOVER = "on_surface/0.09"
local FILL_ON = "primary/0.20"
local FILL_IDLE = FILL_TILE -- chips, swatch backs, cards

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
  local fill = active and FILL_ON or (hover == key and enabled and FILL_HOVER or FILL_TILE)
  return ui.column({
    key = key, flexGrow = 1, gap = 3, paddingV = 9, radius = R_TILE, fill = fill, align = "center",
    opacity = (opt.enabled == false) and 0.35 or 1,
    onClick = enabled and not active and opt.onClick or nil,
    onHover = hoverHandler,
  }, {
    ui.glyph({ name = opt.glyph, size = 19, color = active and "primary" or "on_surface_variant" }),
    ui.label({ text = opt.label, fontSize = 12, fontWeight = active and "semibold" or "normal", color = active and "primary" or "on_surface" }),
  })
end

local function segment(section, opt, selected)
  local key = section .. ":" .. opt.id
  local active = opt.id == selected
  local enabled = opt.enabled ~= false and not busy[section]
  local fill = active and FILL_ON or (hover == key and enabled and FILL_HOVER or nil)
  return ui.row({
    key = key, flexGrow = 1, paddingV = 6, radius = 99, fill = fill, justify = "center", align = "center",
    opacity = (opt.enabled == false) and 0.35 or 1,
    onClick = enabled and not active and opt.onClick or nil,
    onHover = hoverHandler,
  }, {
    ui.label({ text = opt.label, fontSize = 12, fontWeight = active and "semibold" or "normal", color = active and "primary" or "on_surface_variant" }),
  })
end

local function choices(kind, section, options, selected)
  local children = {}
  for _, o in ipairs(options) do
    children[#children + 1] = (kind == "tile" and tile or segment)(section, o, selected)
  end
  if kind == "tile" then return ui.row({ gap = 6 }, children) end
  return ui.row({ gap = 2, padding = 3, radius = 99, fill = FILL_TRACK }, children)
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
  local fill = on and FILL_ON or (hover == key and FILL_HOVER or FILL_IDLE)
  local kids = {}
  if on then kids[#kids + 1] = ui.glyph({ name = "check", size = 13, color = "primary" }) end
  kids[#kids + 1] = ui.label({ text = text, fontSize = 12, color = on and "primary" or "on_surface_variant" })
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

local function keyboardSection()
  if not has(st, "kbd") then return nil end
  local opts = {}
  for i, n in ipairs({ "Off", "Low", "Medium", "High" }) do
    local id = tostring(i - 1)
    opts[#opts + 1] = { id = id, label = n, onClick = function() act("kbd", id, { "kbd", id }) end }
  end
  return section({ iconRow("keyboard", choices("segment", "kbd", opts, picked.kbd or st.kbd)), noteRow("kbd") })
end

local function navButton(id, glyph, text)
  local key = "nav:" .. id
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
    ui.glyph({ name = glyph, size = 15, color = "on_surface_variant" }),
    ui.label({ text = text, fontSize = 12, color = "on_surface_variant" }),
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
  subHeader = subHeader, caption = caption, noteRow = noteRow, packed = packed, parse = parse,
  picked = picked, bin = AWAKECTL,
  render = function() if isOpen then render() end end,
  act = actAwake,
  hover = function() return hover end,
})

local function loadingView(title)
  return { subHeader(title), caption("Reading…") }
end

-- ── power view ────────────────────────────────────────────────────────────────

local function draftFor(mode)
  if drafts[mode] then return drafts[mode] end
  local d1, d2 = num(ex.pl1_default) or 0, num(ex.pl2_default) or 0
  local c = ex["pl_" .. mode] or ""
  local a, b = c:match("^(%d+),(%d+)$")
  drafts[mode] = { pl1 = num(a) or d1, pl2 = num(b) or d2 }
  return drafts[mode]
end

local function powerView()
  if not ex.pl1_default then return loadingView("Power") end
  local mode = powerMode or (PERF_LABEL[st.perf] and st.perf) or "balanced"
  powerMode = mode
  local d = draftFor(mode)
  local max1, max2 = num(ex.pl1_default) or 110, num(ex.pl2_default) or 110
  local custom = (ex["pl_" .. mode] or "") ~= ""
  local changed = d.pl1 ~= (custom and num((ex["pl_" .. mode]):match("^(%d+)")) or max1)
    or d.pl2 ~= (custom and num((ex["pl_" .. mode]):match(",(%d+)$")) or max2)

  local acSel = picked.auto_ac
  if not acSel then
    local p = ex.auto_pending_ac
    acSel = p == "Performance" and "turbo" or p == "Balanced" and "balanced" or ex.auto_ac
  end
  local batSel = picked.auto_battery
  if not batSel then
    local p = ex.auto_pending_battery
    batSel = (ex.bat_silent == "1" or p == "Quiet" or p == "LowPower") and "silent"
      or p == "Performance" and "turbo" or p == "Balanced" and "balanced" or ex.auto_battery
  end
  local function auto(src, id) return function() act("auto_" .. src, id, { "auto", src, id }, "extra") end end

  local modeTabs = {}
  for _, m in ipairs({ "silent", "balanced", "turbo" }) do
    modeTabs[#modeTabs + 1] = { id = m, label = PERF_LABEL[m], onClick = function()
      powerMode = m
      render()
    end }
  end

  -- Without asusd's Quiet, Silent is a pkexec write, so the automatic switch
  -- after each unplug asks for the password.
  local batNote = noteRow("auto_battery")
  if not batNote and batSel == "silent" and ex.silent_needs_root ~= "0" then
    batNote = caption("Switching to Silent after unplugging asks for your password")
  end

  local limits = nil
  if has(ex, "rapl") then
    limits = section({
      label("CPU power limits", custom and "Custom" or "Firmware"),
      choices("segment", "plmode", modeTabs, mode),
      ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = "Sustained", fontSize = 12, color = "on_surface", width = 76 }),
        ui.slider({ key = "pl1:" .. mode, min = 5, max = max1, step = 1, value = d.pl1, flexGrow = 1, controlSize = "sm",
          onChange = function(v)
            d.pl1 = math.floor(tonumber(v) or d.pl1)
            if d.pl2 < d.pl1 then d.pl2 = d.pl1 end
            render()
          end }),
        ui.label({ text = `{d.pl1} W`, fontSize = 12, color = "on_surface_variant", width = 44, textAlign = "end" }),
      }),
      ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = "Boost", fontSize = 12, color = "on_surface", width = 76 }),
        ui.slider({ key = "pl2:" .. mode, min = 5, max = max2, step = 1, value = d.pl2, flexGrow = 1, controlSize = "sm",
          onChange = function(v)
            d.pl2 = math.floor(tonumber(v) or d.pl2)
            if d.pl1 > d.pl2 then d.pl1 = d.pl2 end
            render()
          end }),
        ui.label({ text = `{d.pl2} W`, fontSize = 12, color = "on_surface_variant", width = 44, textAlign = "end" }),
      }),
      ui.row({ gap = 6, justify = "end" }, {
        ui.button({ text = "Reset", controlSize = "sm", variant = "ghost", enabled = custom or changed, onClick = function()
          drafts[mode] = nil
          act("rapl", "reset", { "rapl", "reset", mode }, "extra")
        end }),
        ui.button({ text = "Apply", controlSize = "sm", variant = "secondary", enabled = changed and not busy.rapl, onClick = function()
          act("rapl", "set", { "rapl", "set", mode, tostring(d.pl1), tostring(d.pl2) }, "extra")
          drafts[mode] = nil
        end }),
      }),
      noteRow("rapl") or caption("Caps only. Applying asks for your password"),
    })
  end
  local boost = has(ex, "boost") and toggleRow("CPU boost", (picked.boost or ex.boost) == "1", function(v)
    act("boost", v == "true" and "1" or "0", { "boost", v == "true" and "on" or "off" }, "extra")
  end) or nil

  return packed(
    subHeader("Power", `CPU base {ex.cpu_base_power or "?"} W, dGPU {ex.gpu_base_tgp or "?"} W`),
    section({
      label("When plugged in"),
      choices("segment", "auto_ac", {
        { id = "balanced", label = "Balanced", onClick = auto("ac", "balanced") },
        { id = "turbo", label = "Turbo", onClick = auto("ac", "turbo") },
      }, acSel),
      label("On battery"),
      choices("segment", "auto_battery", {
        { id = "silent", label = "Silent", onClick = auto("battery", "silent") },
        { id = "balanced", label = "Balanced", onClick = auto("battery", "balanced") },
        { id = "turbo", label = "Turbo", onClick = auto("battery", "turbo") },
      }, batSel),
      noteRow("auto_ac"),
      batNote,
    }),
    limits,
    boost,
    boost and noteRow("boost")
  )
end

-- ── fans view ─────────────────────────────────────────────────────────────────

-- Resample an 8-point curve onto an even temperature axis for the graph.
local function curveSamples(spec, t0, t1, n)
  if not spec then return {} end
  local ts, ps = spec:match("^([^;]*);([^;]*)")
  if not ts then return {} end
  local T, P = {}, {}
  for v in ts:gmatch("%d+") do T[#T + 1] = tonumber(v) end
  for v in ps:gmatch("%d+") do P[#P + 1] = tonumber(v) end
  local out = {}
  for i = 0, n - 1 do
    local t = t0 + (t1 - t0) * i / (n - 1)
    local p = P[#P] or 0
    if t <= (T[1] or 0) then
      p = P[1] or 0
    else
      for j = 2, #T do
        if t <= T[j] then
          local f = (t - T[j - 1]) / math.max(1, T[j] - T[j - 1])
          p = P[j - 1] + (P[j] - P[j - 1]) * f
          break
        end
      end
    end
    out[#out + 1] = p / 255
  end
  return out
end

-- Preview curve for a preset without asking rogctl (same maths as fan_preset).
local function presetSpec(spec, preset)
  if not spec or spec == "" or preset == "default" then return spec end
  local ts, ps = spec:match("^([^;]*);([^;]*)")
  if not ts then return spec end
  local T, out, prev = {}, {}, 0
  for v in ts:gmatch("%d+") do T[#T + 1] = tonumber(v) end
  local i = 0
  for v in ps:gmatch("%d+") do
    i += 1
    local p, t = tonumber(v), T[i]
    if preset == "quiet" then
      if t < 60 then p = p * 0.7 elseif t < 70 then p = p * 0.85 end
    elseif preset == "cool" then
      p = p * 1.25 + 8
    end
    p = math.min(255, math.floor(p + 0.5))
    if p < prev then p = prev end
    prev = p
    out[#out + 1] = tostring(p)
  end
  return ts .. ";" .. table.concat(out, ",")
end

local function fansView()
  if not ex.stock_balanced_cpu then return loadingView("Fans") end
  if not has(ex, "fan_curves") then
    return { subHeader("Fans"), caption("This model doesn't expose fan curves") }
  end
  local prof = fanProfile or (st.perf == "turbo" and "performance" or "balanced")
  fanProfile = prof
  local saved = ex["fan_" .. prof] or ""
  local preset = picked["fan_" .. prof] or (saved ~= "" and saved) or "default"
  -- Quiet and Cool are built from the stock curve, seen only while custom
  -- curves are off
  local stockKnown = (ex["stock_" .. prof .. "_cpu"] or "") ~= "" and (ex["stock_" .. prof .. "_gpu"] or "") ~= ""
  local showCpu = presetSpec(ex["stock_" .. prof .. "_cpu"], preset)
  local showGpu = presetSpec(ex["stock_" .. prof .. "_gpu"], preset)

  local function pick(id) return function() act("fan_" .. prof, id, { "fan", prof, id }, "extra") end end
  local rpm = ""
  if st.fan_cpu then rpm = `CPU {st.fan_cpu} rpm, GPU {st.fan_gpu or "0"} rpm` end

  return {
    subHeader("Fans", rpm),
    section({
      label("Curve for"),
      choices("segment", "fanprof", {
        { id = "balanced", label = "Balanced", onClick = function() fanProfile = "balanced"; render() end },
        { id = "performance", label = "Turbo", onClick = function() fanProfile = "performance"; render() end },
      }, prof),
    }),
    ui.column({ gap = 4, padding = 10, radius = R_TILE, fill = FILL_IDLE }, {
      ui.graph({ height = 96, values = curveSamples(showCpu, 30, 90, 31), values2 = curveSamples(showGpu, 30, 90, 31),
        color = "primary", color2 = "tertiary", lineWidth = 2, fillOpacity = 0.12 }),
      ui.row({ align = "center", gap = 10 }, {
        caption("30°"),
        ui.spacer({ flexGrow = 1 }),
        stat("point-filled", "CPU", "primary"),
        stat("point-filled", "GPU", "tertiary"),
        ui.spacer({ flexGrow = 1 }),
        caption("90°"),
      }),
    }),
    section({
      label("Preset"),
      choices("segment", "fan_" .. prof, {
        { id = "default", label = "Stock", onClick = pick("default") },
        { id = "quiet", label = "Quiet", enabled = stockKnown, onClick = pick("quiet") },
        { id = "cool", label = "Cool", enabled = stockKnown, onClick = pick("cool") },
      }, preset),
      noteRow("fan_" .. prof),
      caption(not stockKnown and "Stock curve unknown: pick Stock (or reset curves in asusctl) first"
        or st.perf == "silent" and "Silent always uses the firmware curve" or "Never quieter than stock above 70°"),
    }),
  }
end

-- ── lighting view ─────────────────────────────────────────────────────────────

local SWATCHES = { "ffffff", "ff2a2a", "ff7a00", "28e070", "00d0ff", "3060ff", "a040ff" }

local function swatch(key, hex, selected, onClick, glyph)
  if hex == "000000" then -- "off" for the second colour; black vanishes on OLED
    hex = nil
    glyph = selected and "check" or "x"
  end
  local fill = hex and ("#" .. hex) or FILL_IDLE
  local kids = {}
  if selected or glyph then
    local dark = hex and (tonumber(hex:sub(1, 2), 16) * 0.3 + tonumber(hex:sub(3, 4), 16) * 0.59 + tonumber(hex:sub(5, 6), 16) * 0.11) > 140
    kids[1] = ui.glyph({ name = glyph or "check", size = 14, color = hex and (dark and "#000000" or "#ffffff") or "on_surface_variant" })
  end
  return ui.column({ key = key, width = 24, height = 24, radius = 99, fill = fill, align = "center", justify = "center", onClick = onClick, onHover = hoverHandler }, kids)
end

local function colourRow(which, current, apply)
  local kids = {}
  local seen = false
  local list = {}
  if themeHex then list[#list + 1] = themeHex end
  for _, h in ipairs(SWATCHES) do list[#list + 1] = h end
  if which == 2 then table.insert(list, 1, "000000") end
  for i, h in ipairs(list) do
    local sel = current == h
    if sel then seen = true end
    kids[#kids + 1] = swatch(`sw{which}:{i}`, h, sel, function() apply(h) end)
  end
  -- current colour when it is none of the presets, then the picker
  if current and current ~= "" and not seen then
    kids[#kids + 1] = swatch(`sw{which}:cur`, current, true, nil)
  end
  kids[#kids + 1] = swatch(`sw{which}:pick`, nil, false, function()
    noctalia.openColorPicker("#" .. (current ~= "" and current or "ffffff"), function(color)
      if color then apply(color:gsub("#", ""):sub(1, 6):lower()) end
    end)
  end, "color-picker")
  return ui.row({ gap = 6, align = "center" }, kids)
end

local EFFECTS = {
  { id = "static", ron = "Static", label = "Static" },
  { id = "breathe", ron = "Breathe", label = "Breathe" },
  { id = "pulse", ron = "Pulse", label = "Pulse" },
  { id = "cycle", ron = "RainbowCycle", label = "Cycle" },
  { id = "wave", ron = "RainbowWave", label = "Wave" },
}

local function lightingKeyboard()
  local cur = "static"
  for _, e in ipairs(EFFECTS) do if e.ron == ex.aura_mode then cur = e.id end end
  cur = picked.aura or cur
  local c1, c2, sp = ex.aura_colour or "ffffff", ex.aura_colour2 or "000000", ex.aura_speed or "med"
  local function apply(mode, a, b, s) act("aura", mode, { "aura", mode, a or c1, b or c2, s or sp }, "extra") end

  local effectOpts = {}
  for _, e in ipairs(EFFECTS) do
    effectOpts[#effectOpts + 1] = { id = e.id, label = e.label, onClick = function() apply(e.id) end }
  end
  local kbdOpts = {}
  for i, n in ipairs({ "Off", "Low", "Medium", "High" }) do
    local id = tostring(i - 1)
    kbdOpts[#kbdOpts + 1] = { id = id, label = n, onClick = function() act("kbd", id, { "kbd", id }) end }
  end

  local parts = {}
  if has(st, "kbd") then parts[#parts + 1] = iconRow("sun", choices("segment", "kbd", kbdOpts, picked.kbd or st.kbd)) end
  if not has(ex, "aura") then
    if #parts == 0 then parts[1] = caption("No keyboard lighting controls on this model") end
    return parts
  end
  parts[#parts + 1] = section({ iconRow("sparkles", choices("segment", "aura", effectOpts, cur)), noteRow("aura") })
  if cur == "static" or cur == "breathe" or cur == "pulse" then
    parts[#parts + 1] = section({ label("Colour"), colourRow(1, c1, function(h) apply(cur, h) end) })
  end
  if cur == "breathe" then
    parts[#parts + 1] = section({ label("Second colour"), colourRow(2, c2, function(h) apply(cur, nil, h) end) })
  end
  if cur == "breathe" or cur == "cycle" or cur == "wave" then
    parts[#parts + 1] = iconRow("gauge", choices("segment", "aura_speed", {
      { id = "low", label = "Slow", onClick = function() apply(cur, nil, nil, "low") end },
      { id = "med", label = "Medium", onClick = function() apply(cur, nil, nil, "med") end },
      { id = "high", label = "Fast", onClick = function() apply(cur, nil, nil, "high") end },
    }, sp))
  end
  return parts
end

local function lightingSlash()
  local on = (picked.slash or ex.slash) == "1"
  local modes = {}
  local modeIdx = 0
  for m in (ex.slash_modes or ""):gmatch("[^,]+") do
    modes[#modes + 1] = m
    if m == ex.slash_mode then modeIdx = #modes - 1 end
  end
  local ap = {}
  for v in (ex.aura_power or "1,1,1,1"):gmatch("%d") do ap[#ap + 1] = v == "1" end
  local function powerChip(i, text)
    return chip("ap:" .. i, text, ap[i], function()
      local a = {}
      for j = 1, 4 do a[j] = ((j == i) ~= ap[j]) and "1" or "0" end
      act("aura_power", tostring(i), { "aura-power", a[1], a[2], a[3], a[4] }, "extra")
    end)
  end
  local bright = num(ex.slash_brightness) or 255

  local parts = {}
  if has(ex, "slash") then
    parts[1] = toggleRow("Slash lighting", on, function(v) act("slash", v == "true" and "1" or "0", { "slash", v == "true" and "on" or "off" }, "extra") end)
  end
  if on and has(ex, "slash") then
    parts[#parts + 1] = ui.row({ gap = 8, align = "center" }, {
      ui.select({ options = modes, selectedIndex = modeIdx, controlSize = "sm", flexGrow = 1,
        onChange = function(_i, text) act("slash_mode", text, { "slash", "mode", text }, "extra") end }),
    })
    parts[#parts + 1] = ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = "Brightness", fontSize = 12, color = "on_surface", width = 76 }),
      ui.slider({ key = "slashb", min = 0, max = 255, step = 5, value = bright, flexGrow = 1, controlSize = "sm",
        onChange = function(v) ex.slash_brightness = tostring(math.floor(tonumber(v) or bright)) end,
        onDragEnd = function() act("slash_b", "b", { "slash", "brightness", ex.slash_brightness }, "extra") end }),
    })
    parts[#parts + 1] = ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = "Interval", fontSize = 12, color = "on_surface", width = 76 }),
      ui.slider({ key = "slashi", min = 0, max = 5, step = 1, value = num(ex.slash_interval) or 0, flexGrow = 1, controlSize = "sm",
        onChange = function(v) ex.slash_interval = tostring(math.floor(tonumber(v) or 0)) end,
        onDragEnd = function() act("slash_i", "i", { "slash", "interval", ex.slash_interval }, "extra") end }),
    })
    parts[#parts + 1] = ui.row({ gap = 6 }, {
      chip("sl:bat", "On battery", ex.slash_battery == "1", function()
        act("slash_bat", "x", { "slash", "battery", ex.slash_battery == "1" and "off" or "on" }, "extra")
      end),
      chip("sl:warn", "Low battery warning", ex.slash_warning == "1", function()
        act("slash_warn", "x", { "slash", "warning", ex.slash_warning == "1" and "off" or "on" }, "extra")
      end),
    })
  end
  if ex.aura_power then
    parts[#parts + 1] = section({
      label("Keyboard lights on"),
      ui.row({ gap = 5 }, { powerChip(2, "Awake"), powerChip(3, "Sleep"), powerChip(1, "Boot"), powerChip(4, "Shutdown") }),
      noteRow("aura_power"),
    })
  end
  if has(ex, "boot_sound") then
    parts[#parts + 1] = toggleRow("Boot sound", (picked.boot_sound or ex.boot_sound) == "1", function(v)
      act("boot_sound", v == "true" and "1" or "0", { "boot-sound", v == "true" and "on" or "off" }, "extra")
    end)
  end
  if #parts == 0 then parts[1] = caption("Nothing else to set on this model") end
  return parts
end

local function lightingView()
  if not ex.has_aura then return loadingView("Lighting") end
  local body = {
    subHeader("Lighting"),
    choices("segment", "lighttab", {
      { id = "keyboard", label = "Keyboard", onClick = function() lightTab = "keyboard"; render() end },
      { id = "slash", label = has(ex, "slash") and "Slash and more" or "More", onClick = function() lightTab = "slash"; render() end },
    }, lightTab),
  }
  for _, p in ipairs(lightTab == "keyboard" and lightingKeyboard() or lightingSlash()) do body[#body + 1] = p end
  return body
end

-- ── render / lifecycle ────────────────────────────────────────────────────────

render = function()
  local body
  if view == "power" then body = powerView()
  elseif view == "fans" then body = fansView()
  elseif view == "lighting" then body = lightingView()
  elseif view == "sleep" then body = Awake.view()
  else body = mainView() end
  if noctalia.getConfig("dry_run") == true then
    table.insert(body, 1, caption("Dry run: buttons only show their commands", "tertiary"))
  end
  local kids = {}
  for i = 1, 24 do
    if body[i] then kids[#kids + 1] = body[i] end
  end
  -- keyed by view so retained nodes never carry props across views
  panel.render(ui.column({ flexGrow = 1, gap = 14 }, { ui.column({ key = "view:" .. view, flexGrow = 1, gap = 14 }, kids) }))
end

-- The plugin's dry_run setting has to reach the systemd units too, and they
-- only see ~/.config/rog-helper/dry-run (the bar widget does the same). The
-- flag is written with a marker, so turning the setting off never removes a
-- flag the user touched by hand.
local FLAG_MARK = "set by the ROG helper plugin's dry_run setting\n"
local function syncDryRunFlag()
  local conf = noctalia.getenv("XDG_CONFIG_HOME") or ""
  if conf == "" then conf = noctalia.expandPath("~/.config") end
  local flag = conf .. "/rog-helper/dry-run"
  if noctalia.getConfig("dry_run") == true then
    if not noctalia.fileExists(flag) then
      noctalia.mkdirAll(conf .. "/rog-helper")
      noctalia.writeFile(flag, FLAG_MARK)
    end
  elseif noctalia.fileExists(flag) and noctalia.readFile(flag) == FLAG_MARK then
    noctalia.removeFile(flag)
  end
end

syncDryRunFlag()

function onConfigChanged()
  syncDryRunFlag()
  if isOpen then render() end
end

noctalia.state.watch("rog.draw", function(_v)
  if isOpen and view == "main" then render() end
end)

function onOpen(context)
  isOpen = true
  ticks = 0
  themeHex = readThemeHex()
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
  drafts = {}
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
    lightTab = payload
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
