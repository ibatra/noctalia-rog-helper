--!nonstrict
-- The panel's Power view: per power source profiles, CPU power limits per
-- mode, CPU boost. Changes go through rogctl (the panel's act); the building
-- blocks and snapshots come from panel.luau through setup().

local Power = {}

local B = nil
local st, ex = {}, {} -- the panel's rogctl status / status-extra, fresh each render
local picked, busy
local num, has, act, render, PERF_LABEL
local caption, label, section, choices, noteRow, toggleRow, packed, subHeader, loadingView

local powerMode = nil -- which mode's CPU limits are being edited
local drafts = {} -- mode -> { pl1, pl2 } while editing

function Power.setup(blocks)
  B = blocks
  picked, busy = B.picked, B.busy
  num, has, act, render, PERF_LABEL = B.num, B.has, B.act, B.render, B.PERF_LABEL
  caption, label, section, choices, noteRow = B.caption, B.label, B.section, B.choices, B.noteRow
  toggleRow, packed, subHeader, loadingView = B.toggleRow, B.packed, B.subHeader, B.loadingView
end

-- Unsaved slider positions are dropped when the panel closes.
function Power.reset()
  drafts = {}
end

local function draftFor(mode)
  if drafts[mode] then return drafts[mode] end
  local d1, d2 = num(ex.pl1_default) or 0, num(ex.pl2_default) or 0
  local c = ex["pl_" .. mode] or ""
  local a, b = c:match("^(%d+),(%d+)$")
  drafts[mode] = { pl1 = num(a) or d1, pl2 = num(b) or d2 }
  return drafts[mode]
end

function Power.view()
  st, ex = B.st(), B.ex()
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
        ui.label({ text = d.pl1 .. " W", fontSize = 12, color = "on_surface_variant", width = 44, textAlign = "end" }),
      }),
      ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = "Boost", fontSize = 12, color = "on_surface", width = 76 }),
        ui.slider({ key = "pl2:" .. mode, min = 5, max = max2, step = 1, value = d.pl2, flexGrow = 1, controlSize = "sm",
          onChange = function(v)
            d.pl2 = math.floor(tonumber(v) or d.pl2)
            if d.pl1 > d.pl2 then d.pl1 = d.pl2 end
            render()
          end }),
        ui.label({ text = d.pl2 .. " W", fontSize = 12, color = "on_surface_variant", width = 44, textAlign = "end" }),
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
    subHeader("Power", "CPU base " .. (ex.cpu_base_power or "?") .. " W, dGPU " .. (ex.gpu_base_tgp or "?") .. " W"),
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

return Power
