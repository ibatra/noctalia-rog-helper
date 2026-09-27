--!nonstrict
-- Helpers shared by the panel, the bar widget, the Control Center tile and
-- the Sleep & lid view: required as require("./common.luau").
--
-- Kept to the Lua 5.4 subset of Luau so the headless tests can load it.

local Common = {}

-- `key=value` lines (rogctl / awakectl status) into a table.
function Common.parse(out)
  local t = {}
  for line in (out or ""):gmatch("[^\n]+") do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k then t[k] = v end
  end
  return t
end

-- "1:42", or "42 min" under an hour; rounded up so the last minute never reads 0.
function Common.duration(secs)
  local m = math.ceil(secs / 60)
  if m < 60 then return m .. " min" end
  return string.format("%d:%02d", math.floor(m / 60), m % 60)
end

-- The commands a dry run printed on stderr ("dry-run: <cmd>" lines), shown
-- as a notification whenever the run was a dry run or printed any.
function Common.notifyDryRun(stderr, dry)
  local cmds = {}
  for line in (stderr or ""):gmatch("[^\n]+") do
    local c = line:match("^dry%-run: (.*)$")
    if c then cmds[#cmds + 1] = c end
  end
  if dry or #cmds > 0 then
    noctalia.notify("ROG helper dry run", #cmds > 0 and table.concat(cmds, "\n") or "Nothing to do")
  end
end

-- The plugin's dry_run setting has to reach the systemd units too, and they
-- only see ~/.config/rog-helper/dry-run. The flag is written with a marker, so
-- turning the setting off never removes a flag the user touched by hand.
local FLAG_MARK = "set by the ROG helper plugin's dry_run setting\n"
function Common.syncDryRunFlag()
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

return Common
