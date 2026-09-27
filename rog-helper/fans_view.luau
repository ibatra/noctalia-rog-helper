--!nonstrict
-- The panel's Fans view: the stock curve per profile, previewed with the
-- Quiet/Cool presets rogctl would build from it. Changes go through rogctl
-- (the panel's act); the building blocks come from panel.luau via setup().
--
-- Kept to the Lua 5.4 subset of Luau so tests/fans_view.lua can check the
-- preset maths headless.

local Fans = {}

local B = nil
local st, ex = {}, {} -- the panel's rogctl status / status-extra, fresh each render
local picked
local has, act, render, R_TILE, FILL_IDLE
local caption, label, section, choices, noteRow, stat, subHeader, loadingView

local fanProfile = nil -- balanced | performance

function Fans.setup(blocks)
  B = blocks
  picked = B.picked
  has, act, render, R_TILE, FILL_IDLE = B.has, B.act, B.render, B.R_TILE, B.FILL_IDLE
  caption, label, section, choices, noteRow = B.caption, B.label, B.section, B.choices, B.noteRow
  stat, subHeader, loadingView = B.stat, B.subHeader, B.loadingView
end

-- Resample an 8-point curve onto an even temperature axis for the graph.
function Fans.curveSamples(spec, t0, t1, n)
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
function Fans.presetSpec(spec, preset)
  if not spec or spec == "" or preset == "default" then return spec end
  local ts, ps = spec:match("^([^;]*);([^;]*)")
  if not ts then return spec end
  local T, out, prev = {}, {}, 0
  for v in ts:gmatch("%d+") do T[#T + 1] = tonumber(v) end
  local i = 0
  for v in ps:gmatch("%d+") do
    i = i + 1
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

function Fans.view()
  st, ex = B.st(), B.ex()
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
  local showCpu = Fans.presetSpec(ex["stock_" .. prof .. "_cpu"], preset)
  local showGpu = Fans.presetSpec(ex["stock_" .. prof .. "_gpu"], preset)

  local function pick(id) return function() act("fan_" .. prof, id, { "fan", prof, id }, "extra") end end
  local rpm = ""
  if st.fan_cpu then rpm = "CPU " .. st.fan_cpu .. " rpm, GPU " .. (st.fan_gpu or "0") .. " rpm" end

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
      ui.graph({ height = 96, values = Fans.curveSamples(showCpu, 30, 90, 31), values2 = Fans.curveSamples(showGpu, 30, 90, 31),
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

return Fans
