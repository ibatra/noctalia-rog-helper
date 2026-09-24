--!nonstrict
-- Control Center tile: "Stay awake" toggles the last-used Sleep & lid
-- session (bin/awakectl toggle). Right-click opens the panel's Sleep view.
--
-- Reads the `rog.awake` snapshot the bar widget and the panel already keep
-- fresh; it only runs `awakectl status` itself when nothing has published
-- one yet (a Control Center tile with no rog bar widget on any bar).

local PLUGIN_DIR = noctalia.pluginDir() or noctalia.expandPath("~/.local/share/noctalia-plugins/rog-helper")
local AWAKECTL = PLUGIN_DIR .. "/bin/awakectl"
local PANEL = "ishaan/rog-helper:panel"

local snap = noctalia.state.get("rog.awake")
local loading = false

local function parse(out)
  local t = {}
  for line in (out or ""):gmatch("[^\n]+") do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k then t[k] = v end
  end
  return t
end

local function render()
  local session = type(snap) == "table" and snap.session or nil
  shortcut.setLabel("Stay awake")
  shortcut.setIcon("coffee", "moon")
  shortcut.setActive(session ~= nil and session ~= "none")
  shortcut.setEnabled(true)
end

-- Runs `awakectl status` itself and publishes it, for when no bar widget or
-- open panel has done that yet.
local function refresh()
  if loading then return end
  loading = true
  noctalia.runAsync({ AWAKECTL, "status" }, function(res)
    loading = false
    if res.exitCode == 0 then
      snap = parse(res.stdout)
      noctalia.state.set("rog.awake", snap)
    end
    render()
  end, 5000)
end

noctalia.state.watch("rog.awake", function(value)
  if type(value) == "table" then
    snap = value
    render()
  end
end)

render()

function update()
  noctalia.setUpdateInterval(5000)
  local s = noctalia.state.get("rog.awake")
  if type(s) == "table" then
    snap = s
    render()
  else
    refresh()
  end
end

function onClick()
  noctalia.runAsync({ AWAKECTL, "toggle" }, function()
    refresh()
  end, 5000)
end

function onRightClick()
  -- noctalia.togglePanel takes only a panel id, no context argument, so open
  -- the Sleep view through the IPC form instead, which does take one.
  noctalia.runAsync({ "noctalia", "msg", "panel-open", PANEL, "sleep" })
end
