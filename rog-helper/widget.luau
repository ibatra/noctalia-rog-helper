--!nonstrict
-- ROG helper bar widget: one glyph for the current performance mode.
--
-- Reads sysfs with noctalia.readFile (no subprocess) every 10 s, and refreshes
-- at once when the panel publishes a new status through noctalia.state. The
-- dGPU is only ever inspected through runtime PM, never NVML.

local PANEL = "ishaan/rog-helper:panel"
local FA = "/sys/class/firmware-attributes/asus-armoury/attributes/"
local PP = "/sys/class/platform-profile/"

local PLUGIN_DIR = noctalia.pluginDir() or noctalia.expandPath("~/.local/share/noctalia-plugins/rog-helper")
local AWAKECTL = PLUGIN_DIR .. "/bin/awakectl"

local GLYPH = { silent = "feather", balanced = "scale", turbo = "rocket" }
local PERF_LABEL = { silent = "Silent", balanced = "Balanced", turbo = "Turbo" }

local asusProfile -- resolved once: the asus-wmi platform-profile handler
local dgpuPath -- resolved when the dGPU is present
local batPath -- resolved once: the first BAT* power supply, with a trailing /

local function read(path)
  local s = noctalia.readFile(path)
  return s and noctalia.string.trim(s) or nil
end

local function parseAwake(out)
  local t = {}
  for line in (out or ""):gmatch("[^\n]+") do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k then t[k] = v end
  end
  return t
end

-- "1:42" or "42 min" under an hour; ceil so the last minute never reads 0.
local function awakeDuration(secs)
  local m = math.ceil(secs / 60)
  if m < 60 then return m .. " min" end
  return string.format("%d:%02d", math.floor(m / 60), m % 60)
end

local function resolveHandler()
  local entries = noctalia.listDir(PP)
  for _, e in ipairs(entries or {}) do
    if read(PP .. e .. "/name") == "asus-wmi" then
      return PP .. e .. "/profile"
    end
  end
  return "/sys/firmware/acpi/platform_profile"
end

local function resolveDgpu()
  for _, e in ipairs(noctalia.listDir("/sys/bus/pci/devices/") or {}) do
    local base = "/sys/bus/pci/devices/" .. e
    if read(base .. "/vendor") == "0x10de" and (read(base .. "/class") or ""):sub(1, 4) == "0x03" then
      return base
    end
  end
  return nil
end

local function resolveBattery()
  local names = {}
  for _, e in ipairs(noctalia.listDir("/sys/class/power_supply/") or {}) do
    if e:match("^BAT") then names[#names + 1] = e end
  end
  table.sort(names)
  return names[1] and ("/sys/class/power_supply/" .. names[1] .. "/") or nil
end

local function perfMode()
  asusProfile = asusProfile or resolveHandler()
  local p = read(asusProfile)
  if p == "quiet" or p == "low-power" then return "silent" end
  if p == "performance" then return "turbo" end
  if p == "balanced" then return "balanced" end
  return nil
end

local function gpuText()
  if read(FA .. "dgpu_disable/current_value") == "1" then return "Eco, dGPU off" end
  if dgpuPath == nil or not noctalia.fileExists(dgpuPath) then dgpuPath = resolveDgpu() end
  local mode = read(FA .. "gpu_mux_mode/current_value") == "0" and "Ultimate" or "Standard"
  if not dgpuPath then return mode end
  -- runtime_status only means something with a driver bound
  if not noctalia.fileExists(dgpuPath .. "/driver") then
    return read(dgpuPath .. "/power_state") == "D3cold" and (mode .. ", dGPU off") or mode
  end
  local rt = read(dgpuPath .. "/power/runtime_status")
  if rt == "active" then return mode .. ", dGPU active" end
  if rt == "suspended" then return mode .. ", dGPU suspended" end
  return mode
end

local function render()
  local perf = perfMode()
  local glyphName = GLYPH[perf] or "device-laptop"
  local awake = noctalia.state.get("rog.awake")
  local hasSession = type(awake) == "table" and awake.session ~= nil and awake.session ~= "none"

  -- Once render(tree) has been used, setGlyph only warns: always go through
  -- barWidget.render, even for the plain glyph with no session, so the two
  -- states never straddle the declarative/imperative split.
  local container = barWidget.isVertical() and ui.column or ui.row
  if hasSession then
    barWidget.render(container({ gap = 0, align = "start" }, {
      ui.glyph({ name = glyphName, color = "secondary" }),
      ui.box({ width = 5, height = 5, radius = 3, fill = "primary" }),
    }))
  else
    barWidget.render(container({ align = "start" }, { ui.glyph({ name = glyphName, color = "secondary" }) }))
  end

  local rows = {
    { key = "Performance", value = PERF_LABEL[perf] or "Unknown" },
    { key = "GPU", value = gpuText() },
  }
  batPath = batPath or resolveBattery()
  local limit = batPath and read(batPath .. "charge_control_end_threshold")
  if limit then rows[#rows + 1] = { key = "Battery limit", value = limit .. "%" } end

  if type(awake) == "table" then
    if hasSession then
      local value
      if awake.left == "inf" then
        value = "until stopped"
      else
        local n = tonumber(awake.left or "")
        value = n and (awakeDuration(n) .. " left") or "until stopped"
      end
      rows[#rows + 1] = { key = "Awake", value = value }
    end
    if awake.ac == "1" and awake.lid_ac == "awake" then
      rows[#rows + 1] = { key = "Lid", value = "stays awake on charger" }
    elseif awake.ac == "0" and awake.lid_bat == "awake" then
      rows[#rows + 1] = { key = "Lid", value = "stays awake on battery" }
    end
  end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("rog.status", function(_value)
  render()
end)

noctalia.state.watch("rog.awake", function(_value)
  render()
end)

-- Power draw history for the panel's trace: 36 samples, one per tick (10 s),
-- i.e. the last six minutes. A few sysfs reads, no subprocess. Only a
-- discharging battery measures what the machine draws (charging reads the
-- charge rate, and on AC at the limit it reads about 0), so the trace only
-- samples then and starts over whenever the battery status changes.
local HISTORY = 36
local function sampleDraw()
  batPath = batPath or resolveBattery()
  if not batPath then return end
  -- one sample per tick however many bars carry the widget
  local now = noctalia.nowMs()
  local last = noctalia.state.get("rog.drawAt")
  if type(last) == "number" and now - last < 9000 then return end
  noctalia.state.set("rog.drawAt", now)

  local status = read(batPath .. "status") or ""
  if noctalia.state.get("rog.drawStatus") ~= status then
    noctalia.state.set("rog.drawStatus", status)
    noctalia.state.set("rog.draw", {})
  end
  if status ~= "Discharging" then return end

  local p = tonumber(read(batPath .. "power_now") or "")
  if p then
    p = p / 1e6
  else
    local c, v = tonumber(read(batPath .. "current_now") or ""), tonumber(read(batPath .. "voltage_now") or "")
    if not (c and v) then return end
    p = c * v / 1e12
  end
  p = math.abs(p) -- some drivers report discharge as negative
  local hist = noctalia.state.get("rog.draw") or {}
  local copy = {}
  for i = math.max(1, #hist - HISTORY + 2), #hist do copy[#copy + 1] = hist[i] end
  copy[#copy + 1] = math.floor(p * 10 + 0.5) / 10
  noctalia.state.set("rog.draw", copy)
end

-- Publishes `rog.awake` for the panel's Sleep view and the Control Center
-- tile, at most once per 9 s across every bar instance: the shared
-- `rog.awakeAt` timestamp, same pattern as `rog.drawAt` above.
local function refreshAwake()
  local now = noctalia.nowMs()
  local last = noctalia.state.get("rog.awakeAt")
  if type(last) == "number" and now - last < 9000 then return end
  noctalia.state.set("rog.awakeAt", now)
  noctalia.runAsync({ AWAKECTL, "status" }, function(res)
    if res.exitCode == 0 then
      noctalia.state.set("rog.awake", parseAwake(res.stdout))
    end
    render()
  end, 5000)
end

function update()
  noctalia.setUpdateInterval(10000)
  sampleDraw()
  refreshAwake()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL)
end

-- The plugin's dry_run setting has to reach the systemd units too, and they
-- only see ~/.config/rog-helper/dry-run. The flag is written with a marker, so
-- turning the setting off never removes a flag the user touched by hand.
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

-- So the watcher unit exists (or is reconciled with config) right after
-- install, without waiting for the panel to open or the Control Center tile
-- to be clicked. Skipped in dry-run so it never touches real systemd units.
if noctalia.getConfig("dry_run") ~= true then
  noctalia.runAsync({ AWAKECTL, "sync" }, function() end, 10000)
end

function onConfigChanged()
  syncDryRunFlag()
end

-- The power-source watcher (rog-helper-auto.service) can't show a polkit
-- prompt from a user service, so it asks this widget, which runs inside the
-- session:  noctalia msg plugin ishaan/rog-helper:bar focused act perf:silent
-- A trailing ":dry" means the watcher itself is in dry-run mode.
local ROGCTL = PLUGIN_DIR .. "/bin/rogctl"
local ACTIONS = { ["perf:silent"] = { "perf", "silent" }, ["rapl:apply"] = { "rapl-apply" } }
local BUSY = "rog.bgBusy" -- shared by every instance, so only one acts
function onIpc(event, payload)
  if event ~= "act" or type(payload) ~= "string" then return end
  local what, tail = payload:match("^(%a+:%a+)(.*)$")
  local args = what and ACTIONS[what]
  if not args then return end
  local since = noctalia.state.get(BUSY)
  if type(since) == "number" and noctalia.nowMs() - since < 70000 then return end
  noctalia.state.set(BUSY, noctalia.nowMs())

  local dry = tail == ":dry" or noctalia.getConfig("dry_run") == true
  local argv = { ROGCTL }
  if dry then argv[#argv + 1] = "--dry-run" end
  for _, a in ipairs(args) do argv[#argv + 1] = a end
  noctalia.runAsync(argv, function(res)
    noctalia.state.set(BUSY, 0)
    local cmds = {}
    for line in (res.stderr or ""):gmatch("[^\n]+") do
      local c = line:match("^dry%-run: (.*)$")
      if c then cmds[#cmds + 1] = c end
    end
    if dry or #cmds > 0 then
      noctalia.notify("ROG helper dry run", #cmds > 0 and table.concat(cmds, "\n") or "Nothing to do")
    end
    render()
  end, 60000)
end
