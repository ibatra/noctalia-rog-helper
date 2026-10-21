--!nonstrict
-- Tailscale menu: the macOS menu-bar app's layout in the Apple menu's style.
-- Plain rows, one accent highlight under the pointer, a check column for the
-- choices, thin separators between groups.
--
-- State comes from `tailscale status --json`, `tailscale debug prefs` and
-- `tailscale switch --list`, reloaded on open, every few seconds while open,
-- and after each change. A clicked choice shows as picked straight away and
-- settles on the next reload. Changes need the tailscale operator; when one
-- is refused the menu offers to set it through polkit.

local Common = require("./common.luau")

local REFRESH_EVERY = 4 -- seconds while open
local ADMIN_URL = "https://login.tailscale.com/admin/machines"
local USER = noctalia.getenv("USER") or ((noctalia.expandPath("~") or ""):match("[^/]+$") or "")

local st = nil -- Common.summarize() result
local prefs = {} -- tailscale debug prefs
local profiles = {} -- { id, tailnet, account, current }
local errText = nil
local needsOperator = false
local pending = {} -- what -> optimistic value while its command runs
local note = nil -- { text, tone }

local isOpen = false
local view = "main" -- main | devices | accounts
local hover = ""
local openedAt = 0
local ticks = 0

local render

-- ── loading ───────────────────────────────────────────────────────────────────

local loading, again = false, false

local function parseProfiles(out)
  local list = {}
  local first = true
  for line in (out or ""):gmatch("[^\n]+") do
    if first then
      first = false -- header: ID  Tailnet  Account
    else
      local toks = {}
      for t in line:gmatch("%S+") do toks[#toks + 1] = t end
      if #toks >= 2 then
        local account = toks[#toks]
        local current = account:sub(-1) == "*"
        if current then account = account:sub(1, -2) end
        list[#list + 1] = { id = toks[1], tailnet = #toks >= 3 and toks[2] or "", account = account, current = current }
      end
    end
  end
  return list
end

local function refresh()
  if loading then
    again = true
    return
  end
  loading = true
  local left = 3
  local function done()
    left -= 1
    if left > 0 then return end
    loading = false
    if again then
      again = false
      refresh()
    elseif isOpen then
      render()
    end
  end
  Common.fetch(function(s, err)
    st, errText = s, err
    done()
  end)
  noctalia.runAsync({ "tailscale", "debug", "prefs" }, function(res)
    local d = res.exitCode == 0 and noctalia.json.decode(res.stdout or "") or nil
    if d then
      prefs = d
      needsOperator = (d.OperatorUser or "") ~= USER and USER ~= "root"
    end
    done()
  end, 5000)
  noctalia.runAsync({ "tailscale", "switch", "--list" }, function(res)
    if res.exitCode == 0 then profiles = parseProfiles(res.stdout) end
    done()
  end, 5000)
end

local function run(argv)
  noctalia.runAsync(argv, function() end, 10000)
end

local function closeMenu()
  run({ "noctalia", "msg", "panel-close", Common.PANEL })
end

-- Runs a tailscale command for one setting: `value` shows at once, and the
-- outcome (an error, or a refusal that needs the operator) becomes the note.
local function act(what, value, argv)
  if pending[what] ~= nil then return end
  pending[what] = value
  note = nil
  render()
  noctalia.runAsync(argv, function(res)
    pending[what] = nil
    if res.exitCode ~= 0 then
      local err = noctalia.string.trim((res.stderr or ""):gsub("Warning: client version[^\n]*\n?", ""))
      if err:find("ccess denied", 1, true) or err:find("operator", 1, true) or err:find("permission", 1, true) then
        needsOperator = true
        note = { text = "Tailscale refused the change: it needs the operator set.", tone = "error" }
      elseif res.timedOut then
        note = { text = "Timed out", tone = "error" }
      else
        note = { text = err ~= "" and err or "Failed", tone = "error" }
      end
    end
    refresh()
  end, 30000)
end

local function setFlag(what, flag, on)
  act(what, on, { "tailscale", "set", "--" .. flag .. "=" .. (on and "true" or "false") })
end

local function fixOperator()
  if pending.operator ~= nil then return end
  pending.operator = true
  note = { text = "Waiting for the password prompt…", tone = "muted" }
  render()
  noctalia.runAsync({ "pkexec", "tailscale", "set", "--operator=" .. USER }, function(res)
    pending.operator = nil
    if res.exitCode == 0 then
      note = { text = "Done. Changes no longer need sudo.", tone = "muted" }
    else
      note = { text = "Not changed. Or run: sudo tailscale set --operator=$USER", tone = "error" }
    end
    refresh()
  end, 60000)
end

local function copy(text)
  if not text or text == "" then return end
  closeMenu()
  noctalia.runAsync({ "wl-copy", "--", text }, function(res)
    if res.exitCode == 0 then noctalia.notify("Tailscale", "Copied " .. text) end
  end, 5000)
end

-- ── building blocks (the Apple menu's) ───────────────────────────────────────

-- Pointer callbacks don't always apply their render (see rog-helper), so
-- queue one more for after the callback returns.
local renderQueued = false
local function renderSoon()
  if renderQueued then return end
  renderQueued = true
  noctalia.runAsync({ "true" }, function()
    renderQueued = false
    if isOpen then render() end
  end, 2000)
end

-- Stray enter events arrive while the panel lays out under a stale pointer.
local HOVER_SETTLE_MS = 300

local function hoverHandler(id)
  return function(state)
    local entering = state == "true" or state == true
    if entering and noctalia.nowMs() - openedAt < HOVER_SETTLE_MS then return end
    if entering then
      hover = id
    elseif hover == id then
      hover = ""
    end
    render()
    renderSoon()
  end
end

-- o = { id, label, detail, check (true/false, nil = no check column),
--       glyph, chevron, enabled, onClick, hoverDetail }
local function row(o)
  local enabled = o.enabled ~= false and o.onClick ~= nil
  local hovered = enabled and hover == o.id
  local fill = hovered and "primary" or "surface_variant/0.01"
  local color = hovered and "on_primary" or "on_surface"
  local muted = hovered and "on_primary" or "on_surface_variant"
  local kids = {}
  if o.check ~= nil then
    kids[#kids + 1] = ui.column({ width = 16, align = "center" }, {
      o.check and ui.glyph({ name = "check", size = 14, color = color }) or ui.spacer({ width = 14 }),
    })
  end
  if o.glyph then kids[#kids + 1] = ui.glyph({ name = o.glyph, size = 15, color = muted }) end
  kids[#kids + 1] = ui.label({ text = o.label, fontSize = 13, color = color, flexGrow = 1, maxLines = 1 })
  local detail = hovered and o.hoverDetail or o.detail
  if detail and detail ~= "" then
    kids[#kids + 1] = ui.label({ text = detail, fontSize = 12, color = muted, maxLines = 1 })
  end
  if o.chevron then kids[#kids + 1] = ui.glyph({ name = "chevron-right", size = 14, color = muted }) end
  return ui.row({
    key = o.id, height = 24, paddingH = 8, gap = 6, radius = 5, fill = fill, align = "center",
    opacity = o.enabled == false and 0.4 or 1,
    onClick = enabled and o.onClick or nil, onHover = hoverHandler(o.id),
  }, kids)
end

local function heading(id, text)
  return ui.row({ key = id, height = 20, paddingH = 8, align = "end" }, {
    ui.label({ text = text, fontSize = 11, fontWeight = "semibold", color = "on_surface_variant" }),
  })
end

local sepCount = 0
local function separator()
  sepCount += 1
  return ui.column({ key = "sep" .. sepCount, height = 9, justify = "center", paddingH = 8 }, {
    ui.row({ height = 1, flexGrow = 1, fill = "on_surface/0.18" }, { ui.spacer({ flexGrow = 1 }) }),
  })
end

local function noteRow()
  if not note then return nil end
  return ui.row({ key = "note", paddingH = 8, paddingV = 4 }, {
    ui.label({ text = note.text, fontSize = 11, maxLines = 3, flexGrow = 1,
      color = note.tone == "error" and "error" or "on_surface_variant" }),
  })
end

-- ── views ─────────────────────────────────────────────────────────────────────

local function pick(what, real)
  if pending[what] ~= nil then return pending[what] end
  return real
end

local function stateText(running)
  if errText then return errText end
  if not st then return "Loading…" end
  if st.state == "NeedsLogin" then return "Logged out" end
  if st.state == "Starting" then return "Connecting…" end
  if running then return "Connected" end
  return "Disconnected"
end

local function header(running)
  local canToggle = st ~= nil and st.state ~= "NeedsLogin" and pending.up == nil
  return ui.column({ key = "header", paddingH = 8, paddingV = 4, gap = 1 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = "Tailscale", fontSize = 14, fontWeight = "semibold", color = "on_surface", flexGrow = 1 }),
      ui.toggle({ checked = pick("up", running), enabled = canToggle, onChange = function(v)
        local on = v == true or v == "true"
        act("up", on, { "tailscale", on and "up" or "down" })
      end }),
    }),
    ui.label({ text = stateText(running), fontSize = 11, color = errText and "error" or "on_surface_variant" }),
  })
end

local function mainView(kids, running)
  local add = function(n) if n then kids[#kids + 1] = n end end

  if needsOperator then
    add(row({ id = "operator", glyph = "lock", label = "Allow changes without sudo…", onClick = fixOperator }))
    add(separator())
  end

  if st and st.state == "NeedsLogin" then
    add(row({ id = "login", glyph = "user", label = "Log in…", onClick = function()
      closeMenu()
      run({ "tailscale", "login" }) -- prints a URL tailscaled also opens
      run({ "xdg-open", "https://login.tailscale.com/" })
    end }))
    add(separator())
  end

  if st and running then
    add(row({ id = "self", label = "This Device: " .. st.self.name, detail = st.self.ip,
      hoverDetail = "Copy IP", onClick = function() copy(st.self.ip) end }))
    if #profiles > 1 then
      add(row({ id = "account", label = st.user or st.tailnet or "Account", chevron = true,
        onClick = function() view = "accounts"; hover = ""; render() end }))
    else
      add(row({ id = "account", label = st.user or st.tailnet or "", enabled = false, onClick = function() end }))
    end
    add(separator())

    -- exit nodes
    add(heading("exitHead", "Exit Node"))
    local current = pick("exit", st.exit and st.exit.ip or "")
    add(row({ id = "exit:none", check = current == "", label = "None", onClick = current ~= "" and function()
      act("exit", "", { "tailscale", "set", "--exit-node=" })
    end or nil }))
    for _, p in ipairs(st.exits) do
      local on = current == p.ip
      add(row({ id = "exit:" .. p.id, check = on, label = p.name, detail = not p.online and "Offline" or nil,
        enabled = p.online or on,
        onClick = not on and p.online and function()
          act("exit", p.ip, { "tailscale", "set", "--exit-node=" .. p.ip })
        end or nil }))
    end
    if #st.exits == 0 then
      add(row({ id = "exit:empty", label = "No exit nodes in this tailnet", enabled = false, onClick = function() end }))
    end
    if current ~= "" then
      local lan = pick("lan", prefs.ExitNodeAllowLANAccess == true)
      add(row({ id = "lan", check = lan, label = "Allow Local Network Access",
        onClick = function() setFlag("lan", "exit-node-allow-lan-access", not lan) end }))
    end
    add(separator())

    local online = 0
    for _, p in ipairs(st.peers) do if p.online then online += 1 end end
    add(row({ id = "devices", glyph = "devices", label = "Network Devices", detail = online .. " online", chevron = true,
      onClick = function() view = "devices"; hover = ""; render() end }))
    add(separator())
  end

  if st then
    local dns = pick("dns", prefs.CorpDNS == true)
    local routes = pick("routes", prefs.RouteAll == true)
    local shields = pick("shields", prefs.ShieldsUp == true)
    add(row({ id = "dns", check = dns, label = "Use Tailscale DNS",
      onClick = function() setFlag("dns", "accept-dns", not dns) end }))
    add(row({ id = "routes", check = routes, label = "Use Tailscale Subnets",
      onClick = function() setFlag("routes", "accept-routes", not routes) end }))
    add(row({ id = "shields", check = shields, label = "Block Incoming Connections",
      onClick = function() setFlag("shields", "shields-up", not shields) end }))
    add(separator())
  end

  add(row({ id = "admin", label = "Admin Console…", onClick = function()
    closeMenu()
    run({ "xdg-open", ADMIN_URL })
  end }))
end

local function backRow(title)
  return row({ id = "back", glyph = "chevron-left", label = title, onClick = function()
    view = "main"
    hover = ""
    render()
  end })
end

local function devicesView(kids)
  kids[#kids + 1] = backRow("Network Devices")
  kids[#kids + 1] = separator()
  local mine, shared = {}, {}
  for _, p in ipairs(st and st.peers or {}) do
    local list = p.shared and shared or mine
    list[#list + 1] = p
  end
  local function group(id, title, list)
    if #list == 0 then return end
    kids[#kids + 1] = heading(id, title)
    for _, p in ipairs(list) do
      kids[#kids + 1] = row({
        id = "dev:" .. p.id, glyph = p.glyph, label = p.name,
        detail = p.online and (p.isExit and "Exit node" or p.ip) or "Offline",
        hoverDetail = "Copy " .. (p.ip or ""),
        enabled = p.online, onClick = function() copy(p.ip) end,
      })
    end
  end
  group("mineHead", "My Devices", mine)
  group("sharedHead", "Shared With Me", shared)
  if #mine + #shared == 0 then
    kids[#kids + 1] = row({ id = "dev:none", label = "No other devices", enabled = false, onClick = function() end })
  end
end

local function accountsView(kids)
  kids[#kids + 1] = backRow("Accounts")
  kids[#kids + 1] = separator()
  local current = pick("profile", nil)
  for _, p in ipairs(profiles) do
    local on = current and current == p.id or (current == nil and p.current)
    kids[#kids + 1] = row({
      id = "prof:" .. p.id, check = on, label = p.account, detail = p.tailnet,
      onClick = not on and function() act("profile", p.id, { "tailscale", "switch", p.id }) end or nil,
    })
  end
end

render = function()
  sepCount = 0
  local running = st ~= nil and st.state == "Running"
  local kids = { header(running), separator() }
  if view == "devices" and running then
    devicesView(kids)
  elseif view == "accounts" and #profiles > 1 then
    accountsView(kids)
  else
    view = "main"
    mainView(kids, running)
  end
  local n = noteRow()
  if n then kids[#kids + 1] = n end
  -- keyed by view so retained nodes never carry props across views
  panel.render(ui.scroll({ key = "view:" .. view, flexGrow = 1, gap = 0 }, kids))
end

function onOpen()
  isOpen = true
  openedAt = noctalia.nowMs()
  hover = ""
  view = "main"
  note = nil
  ticks = 0
  render()
  refresh()
  panel.setWantsSecondTicks(true)
end

function onClose()
  isOpen = false
  hover = ""
  panel.setWantsSecondTicks(false)
end

function update()
  if not isOpen then return end
  ticks += 1
  if ticks % REFRESH_EVERY == 0 then refresh() end
end
