--!nonstrict
-- ROG helper bar widget: one glyph for the current performance mode.
--
-- Reads sysfs with noctalia.readFile (no subprocess) every 10 s, and refreshes
-- at once when the panel publishes a new status through noctalia.state. The
-- dGPU is only ever inspected through runtime PM, never NVML.

local PANEL = "ishaan/rog-helper:panel"
local FA = "/sys/class/firmware-attributes/asus-armoury/attributes/"
local PP = "/sys/class/platform-profile/"

local GLYPH = { silent = "feather", balanced = "scale", turbo = "rocket" }
local PERF_LABEL = { silent = "Silent", balanced = "Balanced", turbo = "Turbo" }

local asusProfile -- resolved once: the asus-wmi platform-profile handler
local dgpuPath -- resolved when the dGPU is present

local function read(path)
  local s = noctalia.readFile(path)
  return s and noctalia.string.trim(s) or nil
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
  local rt = dgpuPath and read(dgpuPath .. "/power/runtime_status") or "off"
  local mode = read(FA .. "gpu_mux_mode/current_value") == "0" and "Ultimate" or "Standard"
  if rt == "active" then return mode .. ", dGPU active" end
  if rt == "suspended" then return mode .. ", dGPU suspended" end
  return mode
end

local function render()
  local perf = perfMode()
  barWidget.setGlyph(GLYPH[perf] or "device-laptop")
  barWidget.setGlyphColor("secondary")
  local rows = {
    { key = "Performance", value = PERF_LABEL[perf] or "Unknown" },
    { key = "GPU", value = gpuText() },
  }
  local limit = read("/sys/class/power_supply/BAT1/charge_control_end_threshold")
  if limit then rows[#rows + 1] = { key = "Battery limit", value = limit .. "%" } end
  barWidget.setTooltip(rows)
end

noctalia.state.watch("rog.status", function(_value)
  render()
end)

-- Battery power history for the panel's trace: 36 samples, one per tick
-- (10 s), i.e. the last six minutes. Two sysfs reads, no subprocess.
local HISTORY = 36
local function sampleDraw()
  local bat = "/sys/class/power_supply/BAT1/"
  local p = tonumber(read(bat .. "power_now") or "")
  if p then
    p = p / 1e6
  else
    local c, v = tonumber(read(bat .. "current_now") or ""), tonumber(read(bat .. "voltage_now") or "")
    if not (c and v) then return end
    p = c * v / 1e12
  end
  local hist = noctalia.state.get("rog.draw") or {}
  local copy = {}
  for i = math.max(1, #hist - HISTORY + 2), #hist do copy[#copy + 1] = hist[i] end
  copy[#copy + 1] = math.floor(p * 10 + 0.5) / 10
  noctalia.state.set("rog.draw", copy)
end

function update()
  noctalia.setUpdateInterval(10000)
  sampleDraw()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL)
end

-- The power-source watcher (rog-helper-auto.service) can't show a polkit
-- prompt from a user service, so it asks this widget, which runs inside the
-- session:  noctalia msg plugin ishaan/rog-helper:bar focused act perf:silent
local ROGCTL = (noctalia.pluginDir() or noctalia.expandPath("~/.local/share/noctalia-plugins/rog-helper")) .. "/bin/rogctl"
local running = false
function onIpc(event, payload)
  if event ~= "act" or running then return end
  local argv
  if payload == "perf:silent" then argv = { ROGCTL, "perf", "silent" }
  elseif payload == "rapl:apply" then argv = { ROGCTL, "rapl-apply" } end
  if not argv then return end
  running = true
  noctalia.runAsync(argv, function(_res)
    running = false
    render()
  end, 60000)
end
