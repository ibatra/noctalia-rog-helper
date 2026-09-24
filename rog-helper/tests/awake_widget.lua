-- Headless tests for widget.luau's and shortcut.luau's Sleep & lid dot,
-- tooltip and tile logic, run under plain Lua 5.4:
--   lua rog-helper/tests/awake_widget.lua
-- Each script is loaded with its own isolated _ENV (falling back to the real
-- globals for stdlib), so `update`/`onClick`/... land in that table instead
-- of colliding between the two files, the way tests/awake_view.lua stubs
-- ui/noctalia for awake_view.luau.

local HERE = arg[0]:match("^(.*)/[^/]*$") or "."
local RH = HERE .. "/.."
local passes, fails = 0, 0
local function eq(name, want, got)
  if want == got then passes = passes + 1
  else fails = fails + 1; print(("FAIL %s\n  want: %s\n  got:  %s"):format(name, tostring(want), tostring(got))) end
end

-- `nc.runs` is reassigned to a fresh {} between checks (to "clear" it), so
-- every closure below reaches it through the `nc` upvalue itself, never
-- through a separately named local that would go stale on reassignment.
local function newNoctalia()
  local nc
  local watchers = {}
  nc = {
    runs = {},
    state_ = {},
    pluginDir = function() return RH end,
    expandPath = function(p) return p end,
    getConfig = function(k) if k == "dry_run" then return false end end,
    getenv = function() return "" end,
    readFile = function() return nil end,
    fileExists = function() return false end,
    listDir = function() return {} end,
    string = { trim = function(s) return s:match("^%s*(.-)%s*$") end },
    nowMs = function() return 0 end,
    setUpdateInterval = function() end,
    runAsync = function(argv, cb, timeout) nc.runs[#nc.runs + 1] = { argv = argv, cb = cb, timeout = timeout }; return true end,
    state = {
      get = function(k) return nc.state_[k] end,
      set = function(k, v) nc.state_[k] = v end,
      watch = function(k, cb) watchers[k] = watchers[k] or {}; table.insert(watchers[k], cb) end,
    },
    fire = function(k, v) if watchers[k] then for _, cb in ipairs(watchers[k]) do cb(v) end end end,
    notify = function() end,
  }
  return nc
end

local function loadScript(path, env)
  local chunk = assert(loadfile(path, "t", env))
  local ok, err = pcall(chunk)
  if not ok then error(path .. ": " .. tostring(err)) end
  return env
end

local function args(t) return t and table.concat(t, " ") or "(none)" end

-- ── widget.luau ─────────────────────────────────────────────────────────────

do
  local rendered = {}
  local nc = newNoctalia()
  local env = setmetatable({
    noctalia = nc,
    ui = setmetatable({}, { __index = function(_, k)
      return function(props, kids) return { type = k, props = props or {}, kids = kids } end
    end }),
    barWidget = {
      isVertical = function() return false end,
      render = function(tree) rendered[#rendered + 1] = tree end,
      setTooltip = function(rows) rendered.tooltip = rows end,
      setGlyph = function() error("setGlyph should never be called once render(tree) is in use") end,
      setGlyphColor = function() error("setGlyphColor should never be called once render(tree) is in use") end,
    },
  }, { __index = _G })

  -- resolveHandler/resolveBattery walk sysfs via listDir/readFile stubs that
  -- return nothing, so perfMode() is nil and gpuText()/battery limit are the
  -- "unknown"/absent defaults; that's fine, this check is only about the
  -- awake dot and the Awake/Lid tooltip rows.
  loadScript(RH .. "/widget.luau", env)

  local syncRun = nc.runs[1]
  eq("onload runs awakectl sync", RH .. "/bin/awakectl sync", syncRun and args(syncRun.argv))

  -- render() is a local function, not exported, so drive it through update()
  -- (it also fires refreshAwake(), answered below through the stubbed
  -- runAsync callback).
  rendered = {}
  nc.runs = {}
  env.update()
  local statusRun
  for _, r in ipairs(nc.runs) do if r.argv[2] == "status" then statusRun = r end end
  eq("update() runs awakectl status", RH .. "/bin/awakectl status", statusRun and args(statusRun.argv))

  local function respond(fields)
    local lines = {}
    for k, v in pairs(fields) do lines[#lines + 1] = k .. "=" .. v end
    statusRun.cb({ exitCode = 0, stdout = table.concat(lines, "\n") .. "\n" })
  end

  local function hasKey(rows, key) for _, r in ipairs(rows) do if r.key == key then return true end end; return false end

  rendered = {}
  respond({ session = "none", ac = "1", lid_ac = "sleep", lid_bat = "sleep", left = "" })
  local tree = rendered[#rendered]
  eq("no session: single-child row (glyph only)", 1, #tree.kids)
  eq("no session: no Awake row", false, hasKey(rendered.tooltip, "Awake"))
  eq("no session, lid rules = sleep: no Lid row", false, hasKey(rendered.tooltip, "Lid"))

  rendered = {}
  respond({ session = "system", ac = "1", lid_ac = "awake", lid_bat = "sleep", left = "102" })
  tree = rendered[#rendered]
  eq("session: two children (glyph + dot)", 2, #tree.kids)
  eq("session: dot is a box", "box", tree.kids[2].type)
  local awakeRow, lidRow
  for _, r in ipairs(rendered.tooltip) do
    if r.key == "Awake" then awakeRow = r end
    if r.key == "Lid" then lidRow = r end
  end
  eq("Awake row value (102s -> ceil 2min)", "2 min left", awakeRow and awakeRow.value)
  eq("Lid row on charger", "stays awake on charger", lidRow and lidRow.value)

  rendered = {}
  nc.runs = {}
  env.update()
  for _, r in ipairs(nc.runs) do if r.argv[2] == "status" then statusRun = r end end
  respond({ session = "screen", ac = "0", lid_ac = "awake", lid_bat = "awake", left = "inf" })
  tree = rendered[#rendered]
  awakeRow, lidRow = nil, nil
  for _, r in ipairs(rendered.tooltip) do
    if r.key == "Awake" then awakeRow = r end
    if r.key == "Lid" then lidRow = r end
  end
  eq("Awake row value (inf)", "until stopped", awakeRow and awakeRow.value)
  eq("Lid row on battery", "stays awake on battery", lidRow and lidRow.value)

  -- 9 s cross-instance gate: a second update() right away must not refire.
  nc.runs = {}
  env.update()
  local fired = false
  for _, r in ipairs(nc.runs) do if r.argv[2] == "status" then fired = true end end
  eq("no refire inside the 9s gate", false, fired)

  -- rog.awake published externally (e.g. by the panel) re-renders at once.
  rendered = {}
  nc.state.set("rog.awake", { session = "none" })
  nc.fire("rog.awake", { session = "none" })
  eq("external rog.awake publish re-renders", 1, #rendered)
end

-- ── shortcut.luau ────────────────────────────────────────────────────────────

do
  local nc = newNoctalia()
  local label, icon, active, enabled
  local env = setmetatable({
    noctalia = nc,
    shortcut = {
      setLabel = function(t) label = t end,
      setIcon = function(a, b) icon = { a, b } end,
      setActive = function(b) active = b end,
      setEnabled = function(b) enabled = b end,
    },
  }, { __index = _G })

  loadScript(RH .. "/shortcut.luau", env)
  eq("initial label", "Stay awake", label)
  eq("initial icon", "coffee moon", icon and table.concat(icon, " "))
  eq("initial not active (no snapshot)", false, active)

  -- update(): no rog.awake yet -> runs status itself
  nc.runs = {}
  env.update()
  eq("update() with no snapshot runs status", RH .. "/bin/awakectl status", nc.runs[1] and args(nc.runs[1].argv))
  nc.runs[1].cb({ exitCode = 0, stdout = "session=system\nleft=60\n" })
  eq("active once a session is parsed", true, active)

  -- update(): rog.awake already set -> reads state, no subprocess
  nc.runs = {}
  nc.state.set("rog.awake", { session = "none" })
  env.update()
  eq("update() with a snapshot does not re-run status", 0, #nc.runs)
  eq("inactive once state says none", false, active)

  -- onClick: toggle, then refresh
  nc.runs = {}
  env.onClick()
  eq("onClick runs toggle", RH .. "/bin/awakectl toggle", nc.runs[1] and args(nc.runs[1].argv))
  nc.runs[1].cb({ exitCode = 0 })
  eq("onClick's toggle is followed by a status refresh", RH .. "/bin/awakectl status", nc.runs[2] and args(nc.runs[2].argv))

  -- onRightClick: panel-open with the sleep context (togglePanel has none)
  nc.runs = {}
  env.onRightClick()
  eq("onRightClick opens the Sleep view via IPC", "noctalia msg panel-open ishaan/rog-helper:panel sleep", args(nc.runs[1] and nc.runs[1].argv))

  -- external rog.awake publish updates the tile without a subprocess
  nc.runs = {}
  nc.fire("rog.awake", { session = "screen" })
  eq("external publish sets active", true, active)
  eq("...without a subprocess", 0, #nc.runs)
end

print(("%d passed, %d failed"):format(passes, fails))
os.exit(fails == 0 and 0 or 1)
