--!nonstrict
-- Tailscale menu: the macOS menu-bar app's layout, drawn in Pond's style
-- like the Apple menu: a serif title with the Connect toggle over a hairline,
-- 34 px rows with a grey hover, a white disc + check for the picked exit node
-- or account, Pond toggles for the on/off settings, hairlines between groups.
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

-- ── building blocks (Pond's, shared look with the Apple menu) ────────────────
-- Pond (butterfly.so) tokens as palette roles: rows 34 tall with 12 px
-- corners and a #262626 grey under the pointer (never an accent fill), Onest
-- Medium 13 with secondary text at 50-70%, #3D3D3D hairlines, a serif title
-- over a hairline, a white disc + check for the picked choice, and Pond's
-- rolling red/green toggle for on/off settings.

local ROW_H = 34
local FILL_NONE = "surface_container/0.01" -- a nil fill keeps a retained node's old fill
local FILL_HOVER = "surface_container"     -- Pond #262626
local FILL_PRESSED = "hover"               -- Pond #303030
local HAIRLINE = "outline_variant"         -- Pond #3D3D3D
local TITLE_FONT = "Instrument Serif"      -- stands in for Pond's Gramercy

-- ── fitting the card to its rows ─────────────────────────────────────────────
-- The panel is height = "content" (plugin.toml), so the card hugs its rows
-- like the Pond Wi-Fi / Bluetooth panels and grows up from the bottom-left
-- corner it is pinned to. A ui.scroll has no natural height of its own, so
-- the rows only go in one when they run taller than the card may be; then a
-- fixed-height column holds it. Each builder records its row's height here.
local MAX_H = 592     -- plugin.toml max_height
local PANEL_PAD = 14  -- Noctalia's padding on each side of the content
local ROOT_GAP = 8    -- between the header and the rows
-- a little over the real header heights: main = serif 22 (line 1.3 em, 28.6)
-- + 2 + status line (Onest 12, 15.3) + 12 + hairline = 58.9; sub = 32 + 12 + 1
local HEADER_H = { main = 62, sub = 46 }
local NOTE_LINE = 16  -- one 12 px line
local heights = setmetatable({}, { __mode = "k" })
local function sized(node, h)
  heights[node] = h
  return node
end

-- ui.scroll insets its viewport by a fixed 4 px left/right and 8 px top/bottom
-- in surface pixels (not scaled by ui_scale). Rows
-- outside a scroll get the same inset so they never shift sideways.
local function readUiScale()
  for _, p in ipairs({ "~/.local/state/noctalia/settings.toml", "~/.config/noctalia/config.toml" }) do
    local ok, s = pcall(noctalia.readFile, noctalia.expandPath(p))
    if ok and type(s) == "string" then
      local v = tonumber(s:match("\n%s*ui_scale%s*=%s*([%d%.]+)") or s:match("^%s*ui_scale%s*=%s*([%d%.]+)") or "")
      if v and v > 0.3 and v < 4 then return v end
    end
  end
  return 1
end
local UI_SCALE = readUiScale()
local SCROLL_PAD_H = 4 / UI_SCALE
local SCROLL_PAD_V = 8 / UI_SCALE

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

-- Pond's picked marker: a white disc with a dark check, or a faint ring.
local function checkMark(on)
  if on then
    return ui.row({ width = 16, height = 16, radius = 8, fill = "on_surface", align = "center", justify = "center" }, {
      ui.glyph({ name = "check", size = 11, color = "surface" }),
    })
  end
  return ui.box({ width = 16, height = 16, radius = 8, fill = FILL_NONE, border = "on_surface/0.3", borderWidth = 1 })
end

-- Pond's toggle: a 54x28 outlined pill with faint off/on markers; the knob is
-- red with a dash when off and green with a bar when on. Pond's own literals.
local function pondToggle(on, hovered, enabled)
  local knob = ui.column({ width = 24, height = 24, radius = 12, align = "center", justify = "center",
    fill = on and "#0c3723" or "#613129" }, {
    on and ui.box({ width = 4, height = 12, radius = 2, fill = "#b0ff4f" })
      or ui.box({ width = 12, height = 4, radius = 2, fill = "#fb9b89" }),
  })
  local ghostOff = ui.row({ width = 24, height = 24, align = "center", justify = "center" }, {
    ui.box({ width = 13, height = 5, radius = 2.5, fill = FILL_NONE, border = "#e7e7e74d", borderWidth = 1 }),
  })
  local ghostOn = ui.row({ width = 24, height = 24, align = "center", justify = "center" }, {
    ui.box({ width = 5, height = 13, radius = 2.5, fill = FILL_NONE, border = "#e7e7e74d", borderWidth = 1 }),
  })
  return ui.row({
    width = 54, height = 28, radius = 14, padding = 2, gap = 2, align = "center",
    fill = hovered and FILL_HOVER or FILL_NONE, border = HAIRLINE, borderWidth = 1,
    opacity = enabled == false and 0.4 or 1,
  }, on and { ghostOff, knob } or { knob, ghostOn })
end

-- o = { id, label, detail, check (true/false, nil = no check column),
--       switch (true/false: a trailing Pond toggle, nil = none),
--       glyph, chevron, enabled, onClick, hoverDetail }
local function row(o)
  local enabled = o.enabled ~= false and o.onClick ~= nil
  local hovered = enabled and hover == o.id
  local kids = {}
  if o.check ~= nil then kids[#kids + 1] = checkMark(o.check) end
  if o.glyph then kids[#kids + 1] = ui.glyph({ name = o.glyph, size = 16, color = hovered and "on_surface" or "on_surface/0.7" }) end
  kids[#kids + 1] = ui.label({ text = o.label, fontSize = 13, fontWeight = "medium", color = "on_surface", flexGrow = 1, maxLines = 1 })
  local detail = hovered and o.hoverDetail or o.detail
  if detail and detail ~= "" then
    kids[#kids + 1] = ui.label({ text = detail, fontSize = 13, color = hovered and o.hoverDetail and "on_surface/0.8" or "on_surface/0.5", maxLines = 1 })
  end
  if o.chevron then kids[#kids + 1] = ui.glyph({ name = "chevron-right", size = 14, color = "on_surface/0.5" }) end
  if o.switch ~= nil then kids[#kids + 1] = pondToggle(o.switch, hovered, enabled) end
  return sized(ui.row({
    key = o.id, height = ROW_H, paddingH = 10, gap = 10, radius = 12,
    fill = hovered and FILL_HOVER or FILL_NONE, align = "center",
    opacity = o.enabled == false and 0.4 or 1,
    onClick = enabled and o.onClick or nil, onHover = hoverHandler(o.id),
  }, kids), ROW_H)
end
-- (every row keeps a 10 px inset, so labels, details, chevrons and toggles all
-- share one left and one right edge with the header above)

local function heading(id, text)
  return sized(ui.row({ key = id, height = 24, paddingH = 10, align = "end" }, {
    ui.label({ text = text, fontSize = 12, fontWeight = "medium", color = "on_surface/0.5" }),
  }), 24)
end

local sepCount = 0
local function separator()
  sepCount += 1
  return sized(ui.column({ key = "sep" .. sepCount, height = 9, justify = "center", paddingH = 10 }, {
    ui.row({ height = 1, flexGrow = 1, fill = HAIRLINE }, { ui.spacer({ flexGrow = 1 }) }),
  }), 9)
end

local function hairline(key)
  return ui.row({ key = key, height = 1, fill = HAIRLINE }, { ui.spacer({ flexGrow = 1 }) })
end

local function noteRow()
  if not note then return nil end
  local lines = math.min(3, math.max(1, math.ceil(#note.text / 38))) -- ~38 characters a line
  return sized(ui.row({ key = "note", paddingH = 10, paddingV = 6 }, {
    ui.label({ text = note.text, fontSize = 12, maxLines = 3, flexGrow = 1,
      color = note.tone == "error" and "error" or "on_surface/0.6" }),
  }), 12 + lines * NOTE_LINE)
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

-- Pond's panel header: a serif title (with a back button on a pushed page)
-- and, on the main page, the Connect toggle and a status line under it.
local function backButton()
  local hovered = hover == "back"
  return ui.row({
    key = "back", width = 32, height = 32, radius = 10, align = "center", justify = "center",
    fill = hovered and FILL_PRESSED or FILL_HOVER, border = HAIRLINE, borderWidth = 1,
    onClick = function()
      view = "main"
      hover = ""
      render()
    end,
    onHover = hoverHandler("back"),
  }, { ui.glyph({ name = "chevron-left", size = 16, color = "on_surface" }) })
end

local function title(text)
  return ui.label({ text = text, fontFamily = TITLE_FONT, fontSize = 22, color = "on_surface", maxLines = 1, flexGrow = 1 })
end

local function header(running, subtitle)
  if subtitle then
    -- paddingH on the column, so the hairline spans the text column (Pond)
    return ui.column({ key = "header:" .. subtitle, gap = 12, paddingH = 12 }, {
      ui.row({ height = 32, paddingH = 0, align = "center", gap = 10 }, { backButton(), title(subtitle) }),
      hairline("header:line"),
    })
  end
  local canToggle = st ~= nil and st.state ~= "NeedsLogin" and pending.up == nil
  local on = pick("up", running)
  local status = stateText(running)
  local dot = errText and "error" or (running and "#cbe25b" or "on_surface/0.3") -- Pond's lime = connected
  return ui.column({ key = "header", gap = 12, paddingH = 12 }, {
    ui.row({ paddingH = 0, align = "center", gap = 10 }, { -- explicit 0: retained nodes keep removed props
      ui.column({ flexGrow = 1, gap = 2 }, {
        title("Tailscale"),
        ui.row({ align = "center", gap = 6 }, {
          ui.box({ width = 6, height = 6, radius = 3, fill = dot }),
          ui.label({ text = status, fontSize = 12, color = errText and "error" or "on_surface/0.6", maxLines = 1, flexGrow = 1 }),
        }),
      }),
      ui.row({
        key = "up", align = "center",
        onClick = canToggle and function()
          act("up", not on, { "tailscale", (not on) and "up" or "down" })
        end or nil,
        onHover = hoverHandler("up"),
      }, { pondToggle(on, canToggle and hover == "up", canToggle) }),
    }),
    hairline("header:line"),
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
      add(row({ id = "lan", switch = lan, label = "Allow Local Network Access",
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
    add(row({ id = "dns", switch = dns, label = "Use Tailscale DNS",
      onClick = function() setFlag("dns", "accept-dns", not dns) end }))
    add(row({ id = "routes", switch = routes, label = "Use Tailscale Subnets",
      onClick = function() setFlag("routes", "accept-routes", not routes) end }))
    add(row({ id = "shields", switch = shields, label = "Block Incoming Connections",
      onClick = function() setFlag("shields", "shields-up", not shields) end }))
    add(separator())
  end

  add(row({ id = "admin", label = "Admin Console…", onClick = function()
    closeMenu()
    run({ "xdg-open", ADMIN_URL })
  end }))
end

local function devicesView(kids)
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
  local current = pick("profile", nil)
  for _, p in ipairs(profiles) do
    local on = current and current == p.id or (current == nil and p.current)
    kids[#kids + 1] = row({
      id = "prof:" .. p.id, check = on, label = p.account, detail = p.tailnet,
      onClick = not on and function() act("profile", p.id, { "tailscale", "switch", p.id }) end or nil,
    })
  end
end

-- The rows under the header: a plain column when they fit the card's maximum
-- height, else a scroll in a column of exactly the room left.
local function rows(kids, headerH)
  local natural = 2 * SCROLL_PAD_V
  for _, k in ipairs(kids) do natural += heights[k] or ROW_H end
  local room = MAX_H - 2 * PANEL_PAD - headerH - ROOT_GAP
  if natural <= room then
    return ui.column({ key = "rows:" .. view, paddingH = SCROLL_PAD_H, paddingV = SCROLL_PAD_V, gap = 0 }, kids)
  end
  return ui.column({ key = "rows:" .. view .. ":box", height = room, gap = 0 }, {
    ui.scroll({ key = "rows:" .. view .. ":scroll", flexGrow = 1, gap = 0 }, kids),
  })
end

render = function()
  sepCount = 0
  local running = st ~= nil and st.state == "Running"
  local kids = {}
  local subtitle = nil
  if view == "devices" and running then
    subtitle = "Network Devices"
    devicesView(kids)
  elseif view == "accounts" and #profiles > 1 then
    subtitle = "Accounts"
    accountsView(kids)
  else
    view = "main"
    mainView(kids, running)
  end
  local n = noteRow()
  if n then kids[#kids + 1] = n end
  -- the card hugs header + rows; past the maximum height the header stays
  -- put and the rows scroll under it. Keyed by view so retained nodes never
  -- carry props across views
  panel.render(ui.column({ key = "view:" .. view, gap = ROOT_GAP }, {
    header(running, subtitle),
    rows(kids, subtitle and HEADER_H.sub or HEADER_H.main),
  }))
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

-- Scriptable entry point, also for checking the sub-pages without a pointer:
--   noctalia msg plugin ishaan/tailscale:panel all view devices   (or accounts, main)
-- Only switches the page; it never changes a Tailscale setting.
function onIpc(event, payload)
  if type(payload) ~= "string" or event ~= "view" then return end
  if payload == "main" or payload == "devices" or payload == "accounts" then
    view = payload
    hover = ""
    if isOpen then render() end
  end
end
