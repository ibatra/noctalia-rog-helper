--!nonstrict
-- Sleep & lid: the panel's Sleep sub-view and the Awake row on the main view.
--
-- Reads `awakectl status` and changes things only through awakectl (the
-- panel's actAwake), so this file holds no lid, lock or power logic. The
-- building blocks come from panel.luau through setup().
--
-- Kept to the Lua 5.4 subset of Luau so tests/awake_view.lua can run it
-- headless (`lua rog-helper/tests/awake_view.lua`).

local Awake = {}

local B = nil -- building blocks and panel hooks, from setup()
local snap = nil -- last parsed `awakectl status`
local loading, again = false, false
local batteryDraft = nil -- Battery below, while the slider is dragged

-- B: choices, iconRow, label, section, toggleRow, subHeader, caption, noteRow,
-- packed, parse, picked (the panel's table), bin (awakectl path),
-- render(), act(section, id, args), hover()
function Awake.setup(blocks)
  B = blocks
end

function Awake.snapshot()
  return snap
end

-- Publishes the snapshot as noctalia.state "rog.awake" for the bar widget and
-- the Control Center tile.
function Awake.refresh()
  if not snap then snap = noctalia.state.get("rog.awake") end
  if loading then
    again = true -- the snapshot in flight may predate a change
    return
  end
  loading = true
  noctalia.runAsync({ B.bin, "status" }, function(res)
    loading = false
    if res.exitCode == 0 then
      snap = B.parse(res.stdout)
      noctalia.state.set("rog.awake", snap)
    end
    if again then
      again = false
      Awake.refresh()
    end
    B.render()
  end, 5000)
end

-- ── derived text ──────────────────────────────────────────────────────────────

-- "1:42", or "42 min" under an hour; rounded up so the last minute never reads 0.
local function duration(secs)
  local m = math.ceil(secs / 60)
  if m < 60 then return m .. " min" end
  return string.format("%d:%02d", math.floor(m / 60), m % 60)
end

local function timeLeft(s)
  if s.left == "inf" then return "∞" end
  local n = tonumber(s.left or "")
  return n and duration(n) or nil
end

local function headline(s)
  local n = tonumber(s.left or "")
  if n then return "Awake · " .. duration(n) .. " left" end
  if s.left == "inf" then return "Awake" end
  return "Normal"
end

-- The lid rule for the power source the machine is on now leads to sleep.
local function lidSleeps(s)
  local rule = s.ac == "1" and s.lid_ac or s.lid_bat
  return rule == "sleep" or (rule == "session" and s.session == "none")
end

local function footerText(s)
  local parts = {}
  if (s.why or "") ~= "" then parts[#parts + 1] = s.why end
  local ends = tonumber(s["until"] or "")
  if ends and s.session ~= "none" then parts[#parts + 1] = "ends " .. os.date("%H:%M", ends) end
  local text = nil
  if #parts > 0 then
    text = table.concat(parts, " · ")
  elseif (s.held or "") == "" and lidSleeps(s) then
    text = "Sleeps when the lid closes"
  end
  return text and (text:sub(1, 1):upper() .. text:sub(2)) or nil
end

-- ── controls ──────────────────────────────────────────────────────────────────

-- A track of { id, label } pairs; the pending pick shows first.
local function track(section, pairs_, current, onPick)
  local opts = {}
  for i, p in ipairs(pairs_) do
    local id = p[1]
    opts[i] = { id = id, label = p[2], onClick = function() onPick(id) end }
  end
  return B.choices("segment", section, opts, B.picked[section] or current)
end

-- A track bound to one awakectl setting.
local function setting(key, pairs_)
  return track(key, pairs_, snap[key], function(id) B.act(key, id, { "set", key .. "=" .. id }) end)
end

local function batteryRow(s)
  local saved = tonumber(B.picked.stop_battery or s.stop_battery or "") or 0
  local value = batteryDraft or saved
  return ui.row({ align = "center", gap = 8 }, {
    ui.label({ text = "Battery below", fontSize = 12, color = "on_surface" }),
    ui.slider({ key = "awake:stop_battery", min = 0, max = 50, step = 5, value = value, flexGrow = 1, controlSize = "sm",
      onChange = function(v)
        batteryDraft = math.floor(tonumber(v) or value)
        B.render()
      end,
      onDragEnd = function()
        local n = batteryDraft
        batteryDraft = nil
        if n and n ~= saved then
          B.act("stop_battery", tostring(n), { "set", "stop_battery=" .. n })
        else
          B.render()
        end
      end }),
    ui.label({ text = value == 0 and "Off" or (value .. "%"), fontSize = 12, color = "on_surface_variant", width = 36, textAlign = "end" }),
  })
end

local function flag(key, title, s)
  local on = (B.picked[key] or s[key]) == "1"
  return B.toggleRow(title, on, function(v)
    local id = v == "true" and "1" or "0"
    B.act(key, id, { "set", key .. "=" .. id })
  end)
end

local NOTE_SECTIONS = {
  "awake_kind", "awake_mins", "lid_ac", "lid_bat", "lid_screen", "lid_monitor",
  "power_key", "stop_battery", "stop_unplug", "stop_hot",
}

local function footer(s)
  local parts = {}
  local text = footerText(s)
  if text then parts[1] = B.caption(text) end
  for _, sec in ipairs(NOTE_SECTIONS) do
    local n = B.noteRow(sec)
    if n then parts[#parts + 1] = n end
  end
  if #parts == 0 then return nil end
  return B.section(parts)
end

-- ── views ─────────────────────────────────────────────────────────────────────

-- The ☕ track on the main view: Off ends the session, a duration starts one
-- in the last-used kind.
function Awake.mainRow()
  local s = snap
  if not s then return nil end
  local sel = nil
  if s.session == "none" then sel = "none"
  elseif s["until"] == "inf" then sel = "inf"
  elseif s.mins == "60" or s.mins == "120" then sel = s.mins end
  local kind = (s.kind == "screen") and "screen" or "system"
  local row = track("awake_quick", { { "none", "Off" }, { "60", "1h" }, { "120", "2h" }, { "inf", "∞" } }, sel, function(id)
    if id == "none" then
      B.act("awake_quick", id, { "stop" })
    else
      B.act("awake_quick", id, { "start", kind, id == "inf" and "0" or id })
    end
  end)
  local left = timeLeft(s)
  return B.iconRow("coffee", row, left and B.caption(left) or nil)
end

function Awake.view()
  local s = snap
  if not s then return { B.subHeader("Sleep & lid"), B.caption("Reading…") } end
  local mins = (s.mins or "") ~= "" and s.mins or "60" -- 0 = until stopped
  local function start(kind) return function() B.act("awake_kind", kind, { "start", kind, mins }) end end

  local forSel = s.mins
  if s["until"] == "inf" or (s.session == "none" and s.mins == "0") then forSel = "inf" end
  local forTrack = track("awake_mins", { { "30", "30m" }, { "60", "1h" }, { "120", "2h" }, { "240", "4h" }, { "inf", "∞" } }, forSel, function(id)
    if s.session ~= "none" then
      B.act("awake_mins", id, { "start", s.session, id }) -- restarts the timer from now
    else
      B.act("awake_mins", id, { "set", "mins=" .. (id == "inf" and "0" or id) })
    end
  end)

  local monitor = B.picked.lid_monitor or s.lid_monitor
  local body = B.packed(
    B.choices("tile", "awake_kind", {
      { id = "none", label = "Normal", glyph = "moon", onClick = function() B.act("awake_kind", "none", { "stop" }) end },
      { id = "system", label = "System", glyph = "cpu", onClick = start("system") },
      { id = "screen", label = "Screen on", glyph = "coffee", onClick = start("screen") },
    }, B.picked.awake_kind or s.session),
    B.section({ B.label("For"), forTrack }),
    B.section({
      B.label("Lid closed"),
      B.iconRow("plug", setting("lid_ac", { { "sleep", "Sleep" }, { "awake", "Stay awake" } })),
      B.iconRow("battery-2", setting("lid_bat", { { "sleep", "Sleep" }, { "session", "While awake" }, { "awake", "Stay awake" } })),
      B.iconRow("device-laptop-off", setting("lid_screen", { { "off", "Off" }, { "lock", "Off + lock" } })),
      B.iconRow("device-desktop", setting("lid_monitor", { { "dpms", "Turn off" }, { "disable", "Move windows" } })),
      monitor == "disable" and B.caption("Experimental on this Hyprland: removing a screen can close apps", "tertiary") or nil,
    }),
    B.section({
      B.label("Power button"),
      setting("power_key", { { "none", "Nothing" }, { "lock", "Lock" }, { "sleep", "Sleep" }, { "menu", "Menu" } }),
      s.has_power_key_bind == "0" and B.caption("Add the XF86PowerOff bind from the README first") or nil,
    }),
    B.section({
      B.label("Stop when"),
      batteryRow(s),
      flag("stop_unplug", "Unplugged", s),
      flag("stop_hot", "Hot with lid shut on battery", s),
    }),
    footer(s)
  )
  -- taller than the panel: the header stays, the rest scrolls
  return { B.subHeader("Sleep & lid", headline(s)), ui.scroll({ flexGrow = 1, gap = 14 }, body) }
end

return Awake
