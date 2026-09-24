-- Headless tests for awake_view.luau, run under plain Lua 5.4:
--   lua rog-helper/tests/awake_view.lua
-- ui and noctalia are stubs, and the building blocks record what the view asks
-- for, so a test can read back selections, labels and the awakectl args a
-- click sends without a running Noctalia.

local HERE = arg[0]:match("^(.*)/[^/]*$") or "."
local passes, fails = 0, 0
local function eq(name, want, got)
  if want == got then passes = passes + 1
  else fails = fails + 1; print(("FAIL %s\n  want: %s\n  got:  %s"):format(name, tostring(want), tostring(got))) end
end
local function args(t) return t and table.concat(t, " ") or "(none)" end

-- ── stubs ─────────────────────────────────────────────────────────────────────

local runs, published, stateVals = {}, {}, {}
ui = setmetatable({}, { __index = function(_, k)
  return function(props, kids) return { type = k, props = props or {}, kids = kids } end
end })
noctalia = {
  runAsync = function(argv, cb, timeout) runs[#runs + 1] = { argv = argv, cb = cb, timeout = timeout } end,
  state = {
    set = function(k, v) published[k] = v; stateVals[k] = v end,
    get = function(k) return stateVals[k] end,
  },
  nowMs = function() return 0 end,
}

local picked, acts, renders = {}, {}, 0
local function packed(...)
  local out = {}
  for i = 1, select("#", ...) do local v = select(i, ...); if v then out[#out + 1] = v end end
  return out
end
local function parse(out)
  local t = {}
  for line in (out or ""):gmatch("[^\n]+") do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k then t[k] = v end
  end
  return t
end
local notesOn = {}
local B = {
  bin = "/p/bin/awakectl",
  parse = parse,
  picked = picked,
  packed = packed,
  choices = function(kind, section, options, selected) return { bb = "choices", kind = kind, section = section, options = options, selected = selected } end,
  iconRow = function(glyph, control, trailing) return { bb = "iconRow", glyph = glyph, control = control, trailing = trailing } end,
  label = function(text) return { bb = "label", text = text } end,
  caption = function(text, color) return { bb = "caption", text = text, color = color } end,
  subHeader = function(title, detail) return { bb = "subHeader", title = title, detail = detail } end,
  toggleRow = function(title, checked, onChange) return { bb = "toggle", title = title, checked = checked, onChange = onChange } end,
  noteRow = function(section) return notesOn[section] and { bb = "note", section = section } or nil end,
  section = function(parts)
    local kids = {}
    for i = 1, 16 do if parts[i] then kids[#kids + 1] = parts[i] end end
    return { bb = "section", kids = kids }
  end,
  render = function() renders = renders + 1 end,
  act = function(section, id, a) acts[#acts + 1] = { section = section, id = id, args = a } end,
  hover = function() return "" end,
}

local Awake = assert(loadfile(HERE .. "/../awake_view.luau"))()
Awake.setup(B)

-- depth-first search through tables, skipping functions
local function find(node, pred, seen)
  seen = seen or {}
  if type(node) ~= "table" or seen[node] then return nil end
  seen[node] = true
  if pred(node) then return node end
  for _, v in pairs(node) do
    local hit = find(v, pred, seen)
    if hit then return hit end
  end
  return nil
end
local function findAll(node, pred, out, seen)
  out, seen = out or {}, seen or {}
  if type(node) ~= "table" or seen[node] then return out end
  seen[node] = true
  if pred(node) then out[#out + 1] = node end
  for _, v in pairs(node) do findAll(v, pred, out, seen) end
  return out
end
local function track(tree, section) return find(tree, function(n) return n.bb == "choices" and n.section == section end) end
local function option(ch, id) for _, o in ipairs(ch.options) do if o.id == id then return o end end end
local function click(tree, section, id)
  acts = {}
  option(track(tree, section), id).onClick()
  return acts[1]
end
local function captionText(tree, text) return find(tree, function(n) return n.bb == "caption" and n.text == text end) end
local function slider(tree) return find(tree, function(n) return n.type == "slider" end) end

local BASE = {
  session = "none", kind = "system", mins = "60", ["until"] = "", lid_ac = "awake", lid_bat = "sleep",
  lid_screen = "off", lid_monitor = "dpms", power_key = "none", stop_battery = "20", stop_unplug = "0",
  stop_hot = "1", ac = "1", lid = "open", battery = "80", left = "", held = "", why = "",
  has_power_key_bind = "1", ext = "1",
}
local function status(over)
  local t = {}
  for k, v in pairs(BASE) do t[k] = v end
  for k, v in pairs(over or {}) do t[k] = v end
  local lines = {}
  for k, v in pairs(t) do lines[#lines + 1] = k .. "=" .. v end
  return table.concat(lines, "\n") .. "\n"
end
-- refresh, then answer the status run it started
local function load(over)
  runs = {}
  Awake.refresh()
  local r = runs[#runs]
  r.cb({ exitCode = 0, stdout = status(over), stderr = "" })
end

-- ── before the first snapshot ─────────────────────────────────────────────────

eq("no main row before a snapshot", nil, Awake.mainRow())
eq("sleep view reads first", "Reading…", find(Awake.view(), function(n) return n.bb == "caption" end).text)

-- ── refresh ───────────────────────────────────────────────────────────────────

runs = {}
Awake.refresh()
eq("refresh runs status", "/p/bin/awakectl status", args(runs[1] and runs[1].argv))
Awake.refresh()
eq("a refresh in flight is not doubled", 1, #runs)
renders = 0
runs[1].cb({ exitCode = 0, stdout = status({ mins = "120" }), stderr = "" })
eq("stale refresh reruns once", 2, #runs)
eq("snapshot parsed", "120", Awake.snapshot().mins)
eq("snapshot published", "120", published["rog.awake"] and published["rog.awake"].mins)
eq("refresh renders", 1, renders)
runs[2].cb({ exitCode = 1, stdout = "", stderr = "boom" })
eq("failed status keeps the snapshot", "120", Awake.snapshot().mins)

-- ── header ────────────────────────────────────────────────────────────────────

local function head(over)
  load(over)
  return find(Awake.view(), function(n) return n.bb == "subHeader" end)
end
eq("header title", "Sleep & lid", head().title)
eq("header normal", "Normal", head().detail)
eq("header h:mm", "Awake · 1:42 left", head({ session = "system", left = "6120", ["until"] = "999999" }).detail)
eq("header rounds up to the minute", "Awake · 1:42 left", head({ session = "system", left = "6061", ["until"] = "999999" }).detail)
eq("header under an hour", "Awake · 42 min left", head({ session = "system", left = "2520", ["until"] = "999999" }).detail)
eq("header until stopped", "Awake", head({ session = "screen", left = "inf", ["until"] = "inf" }).detail)

-- ── tiles ─────────────────────────────────────────────────────────────────────

load({ session = "screen", ["until"] = "inf", left = "inf", mins = "0" })
local v = Awake.view()
eq("tiles are tiles", "tile", track(v, "awake_kind").kind)
eq("tile selected from session", "screen", track(v, "awake_kind").selected)
eq("tile glyphs", "moon cpu coffee", option(track(v, "awake_kind"), "none").glyph .. " " .. option(track(v, "awake_kind"), "system").glyph .. " " .. option(track(v, "awake_kind"), "screen").glyph)
eq("tile labels", "Normal System Screen on", option(track(v, "awake_kind"), "none").label .. " " .. option(track(v, "awake_kind"), "system").label .. " " .. option(track(v, "awake_kind"), "screen").label)
eq("Normal stops", "stop", args(click(v, "awake_kind", "none").args))
eq("System starts for the chosen time", "start system 0", args(click(v, "awake_kind", "system").args))
load({ mins = "240" })
eq("Screen on starts for the chosen time", "start screen 240", args(click(Awake.view(), "awake_kind", "screen").args))
picked.awake_kind = "system"
eq("a pending pick shows first", "system", track(Awake.view(), "awake_kind").selected)
picked.awake_kind = nil

-- ── For ───────────────────────────────────────────────────────────────────────

load({ mins = "120" })
v = Awake.view()
eq("For label", "For", find(v, function(n) return n.bb == "label" and n.text == "For" end).text)
local labels = {}
for _, o in ipairs(track(v, "awake_mins").options) do labels[#labels + 1] = o.id .. "=" .. o.label end
eq("For options", "30=30m 60=1h 120=2h 240=4h inf=∞", table.concat(labels, " "))
eq("For selected from mins", "120", track(v, "awake_mins").selected)
eq("For without a session sets mins", "set mins=30", args(click(v, "awake_mins", "30").args))
eq("For ∞ without a session sets 0", "set mins=0", args(click(v, "awake_mins", "inf").args))
load({ mins = "0" })
eq("mins 0 shows ∞", "inf", track(Awake.view(), "awake_mins").selected)
load({ session = "system", mins = "0", ["until"] = "inf", left = "inf" })
v = Awake.view()
eq("until inf shows ∞", "inf", track(v, "awake_mins").selected)
eq("For in a session restarts it", "start system 60", args(click(v, "awake_mins", "60").args))
eq("For ∞ in a session", "start system inf", args(click(v, "awake_mins", "inf").args))
load({ session = "screen", mins = "240", ["until"] = "999999", left = "600" })
eq("timed session shows mins", "240", track(Awake.view(), "awake_mins").selected)

-- ── lid closed ────────────────────────────────────────────────────────────────

load({})
v = Awake.view()
local function row(tree, section)
  return find(tree, function(n) return n.bb == "iconRow" and n.control and n.control.section == section end)
end
local function ids(ch)
  local out = {}
  for _, o in ipairs(ch.options) do out[#out + 1] = o.id .. "=" .. o.label end
  return table.concat(out, " ")
end
eq("lid label", "Lid closed", find(v, function(n) return n.bb == "label" and n.text == "Lid closed" end).text)
eq("charger glyph", "plug", row(v, "lid_ac").glyph)
eq("charger options", "sleep=Sleep awake=Stay awake", ids(row(v, "lid_ac").control))
eq("charger selected", "awake", row(v, "lid_ac").control.selected)
eq("charger sets", "set lid_ac=sleep", args(click(v, "lid_ac", "sleep").args))
eq("battery glyph", "battery-2", row(v, "lid_bat").glyph)
eq("battery options", "sleep=Sleep session=While awake awake=Stay awake", ids(row(v, "lid_bat").control))
eq("battery sets", "set lid_bat=session", args(click(v, "lid_bat", "session").args))
eq("screen glyph", "device-laptop-off", row(v, "lid_screen").glyph)
eq("screen options", "off=Off lock=Off + lock", ids(row(v, "lid_screen").control))
eq("screen sets", "set lid_screen=lock", args(click(v, "lid_screen", "lock").args))
eq("monitor glyph", "device-desktop", row(v, "lid_monitor").glyph)
eq("monitor options", "dpms=Turn off disable=Move windows", ids(row(v, "lid_monitor").control))
eq("monitor sets", "set lid_monitor=disable", args(click(v, "lid_monitor", "disable").args))
local WARN = "Experimental on this Hyprland: removing a screen can close apps"
eq("no warning with Turn off", nil, captionText(v, WARN))
load({ lid_monitor = "disable" })
eq("warning with Move windows", "tertiary", (captionText(Awake.view(), WARN) or {}).color)
load({})
picked.lid_monitor = "disable"
eq("warning follows a pending pick", "tertiary", (captionText(Awake.view(), WARN) or {}).color)
picked.lid_monitor = nil
-- With monitor only shows while an external output is connected
load({ ext = "0" })
eq("no monitor row without an external output", nil, row(Awake.view(), "lid_monitor"))
eq("no monitor glyph without an external output", nil,
  find(Awake.view(), function(n) return n.bb == "iconRow" and n.glyph == "device-desktop" end))
load({ ext = "0", lid_monitor = "disable" })
eq("no warning without an external output", nil, captionText(Awake.view(), WARN))
eq("other lid rows stay without an external output", "plug", row(Awake.view(), "lid_ac").glyph)
load({ ext = "0" })
picked.lid_monitor = "disable"
eq("a pending monitor pick keeps the row", "device-desktop", (row(Awake.view(), "lid_monitor") or {}).glyph)
eq("a pending monitor pick keeps the warning", "tertiary", (captionText(Awake.view(), WARN) or {}).color)
picked.lid_monitor = nil
load({ ext = "1" })
eq("monitor row with an external output", "device-desktop", (row(Awake.view(), "lid_monitor") or {}).glyph)
load({})

-- ── power button ──────────────────────────────────────────────────────────────

local BIND = "Add the XF86PowerOff bind from the README first"
load({ power_key = "lock" })
v = Awake.view()
eq("power options", "none=Nothing lock=Lock sleep=Sleep menu=Menu", ids(track(v, "power_key")))
eq("power selected", "lock", track(v, "power_key").selected)
eq("power sets", "set power_key=menu", args(click(v, "power_key", "menu").args))
eq("no bind note with the bind", nil, captionText(v, BIND))
load({ has_power_key_bind = "0" })
eq("bind note without the bind", BIND, (captionText(Awake.view(), BIND) or {}).text)

-- ── stop when ─────────────────────────────────────────────────────────────────

load({})
v = Awake.view()
local s = slider(v)
eq("slider range", "0 50 5 20", ("%d %d %d %d"):format(s.props.min, s.props.max, s.props.step, s.props.value))
eq("slider label", "20%", (captionText(v, "20%") or find(v, function(n) return n.type == "label" and n.props.text == "20%" end) or { props = {} }).props.text)
acts, renders = {}, 0
s.props.onChange(35)
eq("dragging does not act", 0, #acts)
eq("dragging re-renders", 1, renders)
v = Awake.view()
eq("draft shows while dragging", 35, slider(v).props.value)
slider(v).props.onDragEnd()
eq("drag end sets", "set stop_battery=35", args(acts[1] and acts[1].args))
eq("drag end section", "stop_battery", acts[1] and acts[1].section)
acts = {}
load({ stop_battery = "0" })
v = Awake.view()
eq("0 reads Off", "Off", (find(v, function(n) return n.type == "label" and n.props.text == "Off" end) or { props = {} }).props.text)
slider(v).props.onDragEnd()
eq("drag end with no change does nothing", 0, #acts)

load({ stop_unplug = "0", stop_hot = "1" })
v = Awake.view()
local unplug = find(v, function(n) return n.bb == "toggle" and n.title == "Unplugged" end)
local hot = find(v, function(n) return n.bb == "toggle" and n.title == "Hot with lid shut on battery" end)
eq("unplugged off", false, unplug.checked)
eq("hot on", true, hot.checked)
acts = {}; unplug.onChange("true")
eq("unplugged sets", "set stop_unplug=1", args(acts[1] and acts[1].args))
acts = {}; hot.onChange("false")
eq("hot sets", "set stop_hot=0", args(acts[1] and acts[1].args))

-- ── footer ────────────────────────────────────────────────────────────────────

local function captions(tree)
  local out = {}
  for _, n in ipairs(findAll(tree, function(n) return n.bb == "caption" end)) do out[#out + 1] = n.text end
  table.sort(out)
  return table.concat(out, " | ")
end
load({ session = "system", ["until"] = "1790000000", left = "3000", why = "Awake session · lid closed on charger", held = "sleep,lid" })
eq("why and end time", "Awake session · lid closed on charger · ends " .. os.date("%H:%M", 1790000000),
  (find(Awake.view(), function(n) return n.bb == "caption" and n.text:find("ends", 1, true) end) or {}).text)
load({ ac = "0", lid_bat = "sleep" })
eq("sleeps on battery", "Sleeps when the lid closes", (captionText(Awake.view(), "Sleeps when the lid closes") or {}).text)
load({ ac = "0", lid_bat = "session" })
eq("While awake without a session sleeps", "Sleeps when the lid closes", (captionText(Awake.view(), "Sleeps when the lid closes") or {}).text)
load({ ac = "1", lid_ac = "awake", held = "lid" })
eq("nothing to say", "", captions(Awake.view()))
load({ ac = "1", lid_ac = "sleep", held = "sleep", why = "Awake session", session = "system", ["until"] = "inf", left = "inf" })
eq("why alone", "Awake session", captions(Awake.view()))
notesOn.lid_bat, notesOn.awake_kind = true, true
load({})
local noteSecs = {}
for _, n in ipairs(findAll(Awake.view(), function(n) return n.bb == "note" end)) do noteSecs[#noteSecs + 1] = n.section end
table.sort(noteSecs)
eq("notes for act sections", "awake_kind lid_bat", table.concat(noteSecs, " "))
notesOn = {}

-- ── main row ──────────────────────────────────────────────────────────────────

local function main(over) load(over); return Awake.mainRow() end
local r = main({})
eq("main row glyph", "coffee", r.glyph)
eq("main row options", "none=Off 60=1h 120=2h inf=∞", ids(r.control))
eq("main row is a track", "segment", r.control.kind)
eq("main row off", "none", r.control.selected)
eq("main row no caption", nil, r.trailing)
eq("main row starts last kind", "start system 60", args(click(r, "awake_quick", "60").args))
eq("main row ∞ starts until stopped", "start system 0", args(click(r, "awake_quick", "inf").args))
r = main({ kind = "screen" })
eq("main row uses the last kind", "start screen 120", args(click(r, "awake_quick", "120").args))
r = main({ session = "system", mins = "120", ["until"] = "999999", left = "6120" })
eq("main row timed", "120", r.control.selected)
eq("main row time left", "1:42", r.trailing and r.trailing.text)
eq("main row Off stops", "stop", args(click(r, "awake_quick", "none").args))
r = main({ session = "system", mins = "240", ["until"] = "999999", left = "600" })
eq("main row other durations select nothing", nil, r.control.selected)
eq("main row minutes", "10 min", r.trailing and r.trailing.text)
r = main({ session = "screen", mins = "0", ["until"] = "inf", left = "inf" })
eq("main row until stopped", "inf", r.control.selected)
eq("main row ∞ caption", "∞", r.trailing and r.trailing.text)
picked.awake_quick = "60"
eq("main row pending pick", "60", Awake.mainRow().control.selected)
picked.awake_quick = nil

print(("%d passed, %d failed"):format(passes, fails))
os.exit(fails == 0 and 0 or 1)
