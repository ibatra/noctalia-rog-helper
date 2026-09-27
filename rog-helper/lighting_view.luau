--!nonstrict
-- The panel's Lighting view: keyboard effect, colours and speed; Slash, the
-- keyboard's power states and the boot sound. Changes go through rogctl (the
-- panel's act); the building blocks come from panel.luau through setup().

local Lighting = {}

local B = nil
local st, ex = {}, {} -- the panel's rogctl status / status-extra, fresh each render
local picked
local num, has, act, render, hoverHandler, FILL_IDLE, kbdOptions
local caption, label, section, choices, iconRow, chip, noteRow, toggleRow, subHeader, loadingView

local lightTab = "keyboard" -- keyboard | slash
local themeHex = nil -- the theme's primary, offered as a keyboard colour

function Lighting.setup(blocks)
  B = blocks
  picked = B.picked
  num, has, act, render, hoverHandler = B.num, B.has, B.act, B.render, B.hoverHandler
  FILL_IDLE, kbdOptions = B.FILL_IDLE, B.kbdOptions
  caption, label, section, choices, iconRow = B.caption, B.label, B.section, B.choices, B.iconRow
  chip, noteRow, toggleRow, subHeader, loadingView = B.chip, B.noteRow, B.toggleRow, B.subHeader, B.loadingView
end

-- Keyboard | Slash and more (IPC: tab keyboard|slash).
function Lighting.setTab(tab)
  lightTab = tab
end

-- Theme primary as RRGGBB, from the palette Noctalia writes for Hyprland:
-- a keyboard colour that matches the theme. Read each time the panel opens.
function Lighting.readTheme()
  local s = noctalia.readFile("~/.config/hypr/noctalia.lua") or ""
  local hex = s:match('local primary = "rgb%((%x%x%x%x%x%x)%)"')
  if not hex then
    local css = noctalia.readFile("~/.config/gtk-4.0/noctalia.css") or ""
    hex = css:match("@define%-color accent_color #(%x%x%x%x%x%x)") or css:match("primary[^#]*#(%x%x%x%x%x%x)")
  end
  themeHex = hex and hex:lower() or nil
end

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
  return ui.column({ key = key, width = 24, height = 24, radius = 99, fill = fill, align = "center", justify = "center", onClick = onClick, onHover = hoverHandler(key) }, kids)
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
    kids[#kids + 1] = swatch("sw" .. which .. ":" .. i, h, sel, function() apply(h) end)
  end
  -- current colour when it is none of the presets, then the picker
  if current and current ~= "" and not seen then
    kids[#kids + 1] = swatch("sw" .. which .. ":cur", current, true, nil)
  end
  kids[#kids + 1] = swatch("sw" .. which .. ":pick", nil, false, function()
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
  local kbdOpts = kbdOptions()

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

function Lighting.view()
  st, ex = B.st(), B.ex()
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

return Lighting
