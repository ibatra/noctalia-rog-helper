--!nonstrict
-- Tailscale menu: the macOS menu-bar app's layout, drawn in Pond's style,
-- with a serif title and the Connect toggle over a hairline,
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
-- like the Pond Wi-Fi / Bluetooth panels and grows down from the top-right
-- corner it is pinned to. A ui.scroll has no natural height of its own, so
-- the rows only go in one when they run taller than the card may be; then a
-- fixed-height column holds it. Each builder records its row's height here.
local MAX_H = 592     -- plugin.toml max_height
local PANEL_PAD = 14  -- Noctalia's padding on each side of the content
local ROOT_GAP = 8    -- between the header and the rows
-- a little over the real header heights: main = the 32 px title row (the
-- toggle's 28, the serif 22's 28.6 line) + 12 + hairline = 45, plus 2 + a
-- status line (Onest 12, 15.3) when one shows; sub = 32 + 12 + 1
local HEADER_H = { main = 46, status = 62, sub = 46 }
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

-- ── the grid (pond-panels' style.luau) ──
-- Noctalia pads the panel by 14; hover pills fill that content box and
-- everything you read sits GRID further in, so the title, its hairline, row
-- glyphs and labels, headings and separators share the 24 px text edge of the
-- Pond panels that open in this same top-right slot. Rows sit in the rows
-- column (or its ui.scroll), already SCROLL_PAD_H in, so they take ROW_PAD.
local GRID = 10
local ROW_PAD = GRID - SCROLL_PAD_H

-- Scroll fade (pond-panels' Style.list, standalone here): the API has no
-- gradients or overlays, so a row cut off by the scroll's edge is faded by
-- how much of it shows, 0.1 + 0.9 * shown^2 in 0.05 steps; rows that show
-- whole stay at 1. Works at both edges, so the top fade only appears once the
-- list is scrolled, as in Pond. tops/sizes are each row's y and height.
local scroll = { offset = 0, sig = "" }
-- Rows are built in order, so each builder takes the next index's fade:
-- render() builds once to measure, and again with the fades when the rows
-- scroll.
local fadeByIndex, buildIndex = {}, 0
local function takeFade()
  buildIndex += 1
  return fadeByIndex[buildIndex] or 1
end
local function rowFades(tops, sizes, offset, boxH)
  local top = offset - SCROLL_PAD_V -- content y at the box's top edge
  local bottom = top + boxH
  local fades, sig = {}, {}
  for i = 1, #tops do
    local y0, y1 = tops[i], tops[i] + sizes[i]
    local shown = (math.min(y1, bottom) - math.max(y0, top)) / sizes[i]
    if shown < 0.999 then
      shown = math.max(0, shown)
      local a = math.floor((0.1 + 0.9 * shown * shown) * 20 + 0.5) / 20
      fades[i] = a
      sig[#sig + 1] = i .. "=" .. a
    end
  end
  return fades, table.concat(sig, ",")
end

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

-- Pond's toggle (Toggle.qml): a 54x28 outlined pill with faint off/on
-- markers; the knob is red with a dash when off and green with a bar when on
-- (Pond's literals), and it rolls: over 200 ms on Pond's ease
-- (cubic-bezier 0.77, 0, 0.175, 1) it slides the 26 px across, its colours
-- cross-fade, and the dash turns into the bar over the knob's last quarter
-- turn (Pond rotates it for the last 12 x pi/2 = 18.85 px of travel; here the
-- mark's width and height trade places). The same switch as rog-helper's,
-- standalone here. The UI tree has no overlays, so the knob moves between two
-- spacers and the faint markers only show while it rests. A render while any
-- knob is moving asks for frame ticks; idle, none.
local TOGGLE_MS = 200
local TRAVEL = 26          -- 54 - 24 knob - 2 x 2 padding
local ROLL_FROM = TRAVEL - 12 * math.pi / 2 -- 7.15: where the quarter turn starts
local toggleAnims = {}     -- toggle key -> { from, to, t0 } (position 0..1)
local toggleMoving = false -- set by any knob still moving in this render
local frameTickOn = false

-- Pond's easing curve, x(t) solved for t by Newton's method, then y(t).
local function bezier(u)
  if u <= 0 then return 0 elseif u >= 1 then return 1 end
  local x1, y1, x2, y2 = 0.77, 0, 0.175, 1
  local function at(t, a, b) return 3 * (1 - t) ^ 2 * t * a + 3 * (1 - t) * t * t * b + t ^ 3 end
  local function slope(t, a, b) return 3 * (1 - t) ^ 2 * a + 6 * (1 - t) * t * (b - a) + 3 * t * t * (1 - b) end
  local t = u
  for _ = 1, 8 do
    local d = slope(t, x1, x2)
    if math.abs(d) < 1e-6 then break end
    t = math.clamp(t - (at(t, x1, x2) - u) / d, 0, 1)
  end
  return at(t, y1, y2)
end

local function hexLerp(a, b, p)
  local out = "#"
  for i = 2, 6, 2 do
    local x, y = tonumber(a:sub(i, i + 1), 16), tonumber(b:sub(i, i + 1), 16)
    out ..= string.format("%02x", math.floor(x + (y - x) * p + 0.5))
  end
  return out
end

-- The knob's position (0 off .. 1 on) for this render, and whether it moves.
-- The rows are built twice when they scroll; both builds read the same clock
-- closely enough, and the first build sets the animation the second reuses.
local function togglePosition(key, on)
  local target = on and 1 or 0
  local now = noctalia.nowMs()
  local a = toggleAnims[key]
  local function at(anim)
    local u = (now - anim.t0) / TOGGLE_MS
    if u >= 1 then return anim.to, false end
    return anim.from + (anim.to - anim.from) * bezier(u), true
  end
  if not a then
    a = { from = target, to = target, t0 = 0 }
    toggleAnims[key] = a
  elseif a.to ~= target then
    local p = at(a) -- turn back from wherever the knob is now
    a.from, a.to, a.t0 = p, target, now
  end
  local p, moving = at(a)
  if moving then toggleMoving = true end
  return p, moving
end

local function pondToggle(key, on, hovered, enabled)
  local p, moving = togglePosition(key, on)
  local q = math.clamp((TRAVEL * p - ROLL_FROM) / (TRAVEL - ROLL_FROM), 0, 1)
  local knob = ui.column({ key = key .. ":knob", width = 24, height = 24, radius = 12, align = "center", justify = "center",
    fill = hexLerp("#613129", "#0c3723", p) }, {
    ui.box({ key = key .. ":mark", width = 12 - 8 * q, height = 4 + 8 * q, radius = 2, fill = hexLerp("#fb9b89", "#b0ff4f", p) }),
  })
  -- Pond's outlines sit centred on the knob's two resting places
  local function ghost(w, h)
    return ui.row({ width = 24, height = 24, align = "center", justify = "center" }, {
      ui.box({ width = w, height = h, radius = 2.5, fill = FILL_NONE, border = "#e7e7e74d", borderWidth = 1 }),
    })
  end
  local left, right = {}, {}
  if not moving and p >= 1 then left = { ghost(13, 5), ui.spacer({ width = 2, flexGrow = 0 }) } end
  if not moving and p <= 0 then right = { ui.spacer({ width = 2, flexGrow = 0 }), ghost(5, 13) } end
  return ui.row({
    key = key .. ":pill", width = 54, height = 28, radius = 14, padding = 2, gap = 0, align = "center",
    fill = hovered and FILL_HOVER or FILL_NONE, border = HAIRLINE, borderWidth = 1,
    opacity = enabled == false and 0.4 or 1,
  }, {
    ui.row({ key = key .. ":before", width = TRAVEL * p, height = 24, gap = 0, align = "center" }, left),
    knob,
    ui.row({ key = key .. ":after", width = TRAVEL * (1 - p), height = 24, gap = 0, align = "center" }, right),
  })
end

-- o = { id, label, detail, check (true/false, nil = no check column),
--       switch (true/false: a trailing Pond toggle, nil = none),
--       glyph, chevron, enabled, onClick, hoverDetail }
local function row(o)
  local fade = takeFade()
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
  if o.switch ~= nil then kids[#kids + 1] = pondToggle("sw:" .. o.id, o.switch, hovered, enabled) end
  return sized(ui.row({
    key = o.id, height = ROW_H, paddingH = ROW_PAD, gap = 10, radius = 12,
    fill = hovered and FILL_HOVER or FILL_NONE, align = "center",
    opacity = (o.enabled == false and 0.4 or 1) * fade,
    onClick = enabled and o.onClick or nil, onHover = hoverHandler(o.id),
  }, kids), ROW_H)
end
-- (every row keeps the ROW_PAD inset, so labels, details, chevrons and toggles
-- all share one left and one right edge with the header above)

local function heading(id, text)
  local fade = takeFade()
  return sized(ui.row({ key = id, height = 24, paddingH = ROW_PAD, align = "end", opacity = fade }, {
    ui.label({ text = text, fontSize = 12, fontWeight = "medium", color = "on_surface/0.5" }),
  }), 24)
end

local sepCount = 0
local function separator()
  sepCount += 1
  local fade = takeFade()
  return sized(ui.column({ key = "sep" .. sepCount, height = 9, justify = "center", paddingH = ROW_PAD, opacity = fade }, {
    ui.row({ height = 1, flexGrow = 1, fill = HAIRLINE }, { ui.spacer({ flexGrow = 1 }) }),
  }), 9)
end

local function hairline(key)
  return ui.row({ key = key, height = 1, fill = HAIRLINE }, { ui.spacer({ flexGrow = 1 }) })
end

local function noteRow()
  if not note then return nil end
  local fade = takeFade()
  local lines = math.min(3, math.max(1, math.ceil(#note.text / 38))) -- ~38 characters a line
  return sized(ui.row({ key = "note", paddingH = ROW_PAD, paddingV = 6, opacity = fade }, {
    ui.label({ text = note.text, fontSize = 12, maxLines = 3, flexGrow = 1,
      color = note.tone == "error" and "error" or "on_surface/0.6" }),
  }), 12 + lines * NOTE_LINE)
end

-- ── views ─────────────────────────────────────────────────────────────────────

local function pick(what, real)
  if pending[what] ~= nil then return pending[what] end
  return real
end

-- The status line under the title: only for what the toggle can't say.
local function statusShown()
  return errText ~= nil or (st ~= nil and (st.state == "NeedsLogin" or st.state == "Starting"))
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
-- and, on the main page, the Connect toggle. The toggle already says
-- connected or not, so a status line only shows when it has more to say
-- (logged out, connecting, an error).
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
    return ui.column({ key = "header:" .. subtitle, gap = 12, paddingH = GRID }, {
      ui.row({ height = 32, paddingH = 0, align = "center", gap = 10 }, { backButton(), title(subtitle) }),
      hairline("header:line"),
    })
  end
  local canToggle = st ~= nil and st.state ~= "NeedsLogin" and pending.up == nil
  local on = pick("up", running)
  local status = stateText(running)
  local dot = errText and "error" or (running and "#cbe25b" or "on_surface/0.3") -- Pond's lime = connected
  local titleKids = { title("Tailscale") }
  if statusShown() then
    titleKids[2] = ui.row({ key = "status", align = "center", gap = 6 }, {
      ui.box({ width = 6, height = 6, radius = 3, fill = dot }),
      ui.label({ text = status, fontSize = 12, color = errText and "error" or "on_surface/0.6", maxLines = 1, flexGrow = 1 }),
    })
  end
  return ui.column({ key = "header", gap = 12, paddingH = GRID }, {
    ui.row({ paddingH = 0, align = "center", gap = 10, minHeight = 32 }, { -- explicit 0: retained nodes keep removed props
      ui.column({ flexGrow = 1, gap = 2 }, titleKids),
      ui.row({
        key = "up", align = "center",
        onClick = canToggle and function()
          act("up", not on, { "tailscale", (not on) and "up" or "down" })
        end or nil,
        onHover = hoverHandler("up"),
      }, { pondToggle("sw:up", on, canToggle and hover == "up", canToggle) }),
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
    add(row({ id = "self", glyph = "device-laptop", label = st.self.name, detail = st.self.ip,
      hoverDetail = "Copy IP", onClick = function() copy(st.self.ip) end }))
    if #profiles > 1 then
      add(row({ id = "account", glyph = "user", label = st.user or st.tailnet or "Account", chevron = true,
        onClick = function() view = "accounts"; hover = ""; render() end }))
    else
      add(row({ id = "account", glyph = "user", label = st.user or st.tailnet or "", enabled = false, onClick = function() end }))
    end
    add(separator())

    -- exit nodes
    add(heading("exitHead", "Exit node"))
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
      add(row({ id = "lan", switch = lan, label = "Allow local network access",
        onClick = function() setFlag("lan", "exit-node-allow-lan-access", not lan) end }))
    end
    add(separator())

    local online = 0
    for _, p in ipairs(st.peers) do if p.online then online += 1 end end
    add(row({ id = "devices", glyph = "devices", label = "Network devices", detail = online .. " online", chevron = true,
      onClick = function() view = "devices"; hover = ""; render() end }))
    add(separator())
  end

  if st then
    local dns = pick("dns", prefs.CorpDNS == true)
    local routes = pick("routes", prefs.RouteAll == true)
    local shields = pick("shields", prefs.ShieldsUp == true)
    add(row({ id = "dns", switch = dns, label = "Use Tailscale DNS",
      onClick = function() setFlag("dns", "accept-dns", not dns) end }))
    add(row({ id = "routes", switch = routes, label = "Use Tailscale subnets",
      onClick = function() setFlag("routes", "accept-routes", not routes) end }))
    add(row({ id = "shields", switch = shields, label = "Block incoming connections",
      onClick = function() setFlag("shields", "shields-up", not shields) end }))
    add(separator())
  end

  add(row({ id = "admin", label = "Admin console…", onClick = function()
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
  group("mineHead", "My devices", mine)
  group("sharedHead", "Shared with me", shared)
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
-- height, else a scroll in a column of exactly the room left, its edge rows
-- faded (rowFades). build() makes the rows; it runs again with the fades.
local function rows(build, headerH)
  local function make(fades)
    fadeByIndex, buildIndex, sepCount = fades, 0, 0
    return build()
  end
  local kids = make({})
  local natural = 2 * SCROLL_PAD_V
  local tops, sizes = {}, {}
  for i, k in ipairs(kids) do
    tops[i], sizes[i] = natural - 2 * SCROLL_PAD_V, heights[k] or ROW_H -- y in the scroll's content
    natural += sizes[i]
  end
  local room = MAX_H - 2 * PANEL_PAD - headerH - ROOT_GAP
  if natural <= room then
    scroll.offset, scroll.sig = 0, ""
    return ui.column({ key = "rows:" .. view, paddingH = SCROLL_PAD_H, paddingV = SCROLL_PAD_V, gap = 0 }, kids)
  end
  local fades, sig = rowFades(tops, sizes, scroll.offset, room)
  scroll.sig = sig
  kids = make(fades)
  fadeByIndex = {}
  return ui.column({ key = "rows:" .. view .. ":box", height = room, gap = 0 }, {
    ui.scroll({ key = "rows:" .. view .. ":scroll", flexGrow = 1, gap = 0,
      onScroll = function(offset, _maxOffset)
        local v = tonumber(offset)
        if not v then return end
        scroll.offset = v / UI_SCALE -- surface px -> our units
        local _, nextSig = rowFades(tops, sizes, scroll.offset, room)
        if nextSig ~= scroll.sig and isOpen then render() end
      end }, kids),
  })
end

local lastView = nil
render = function()
  toggleMoving = false
  local running = st ~= nil and st.state == "Running"
  local subtitle = nil
  if view == "devices" and running then
    subtitle = "Network devices"
  elseif view == "accounts" and #profiles > 1 then
    subtitle = "Accounts"
  else
    view = "main"
  end
  -- a page coming back starts at its top
  if view ~= lastView then scroll.offset, scroll.sig, lastView = 0, "", view end
  local function build()
    local kids = {}
    if view == "devices" then devicesView(kids)
    elseif view == "accounts" then accountsView(kids)
    else mainView(kids, running) end
    local n = noteRow()
    if n then kids[#kids + 1] = n end
    return kids
  end
  local headerH = subtitle and HEADER_H.sub or (statusShown() and HEADER_H.status or HEADER_H.main)
  -- the card hugs header + rows; past the maximum height the header stays
  -- put and the rows scroll under it. Keyed by view so retained nodes never
  -- carry props across views
  panel.render(ui.column({ key = "view:" .. view, gap = ROOT_GAP }, {
    header(running, subtitle),
    rows(build, headerH),
  }))
  -- frame ticks only while a toggle's knob is rolling
  if toggleMoving ~= frameTickOn then
    frameTickOn = toggleMoving
    panel.setNeedsFrameTick(toggleMoving)
  end
end

function onFrameTick(_deltaMs)
  if isOpen then render() end
end

function onOpen()
  isOpen = true
  openedAt = noctalia.nowMs()
  hover = ""
  view = "main"
  note = nil
  ticks = 0
  scroll.offset, scroll.sig = 0, ""
  toggleAnims = {} -- a switch flipped while closed shows its new side, no roll
  render()
  refresh()
  panel.setWantsSecondTicks(true)
end

function onClose()
  isOpen = false
  hover = ""
  panel.setWantsSecondTicks(false)
  if frameTickOn then
    frameTickOn = false
    panel.setNeedsFrameTick(false)
  end
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
