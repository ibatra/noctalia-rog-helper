--!nonstrict
-- Shared by the bar widget and the panel: reads `tailscale status --json`
-- into a flat summary and publishes it as `ts.status`, so the bar glyph
-- follows changes made from the menu straight away.

local Common = {}

Common.PANEL = "ishaan/tailscale:panel"

-- The name the Mac app would show: HostName, except for devices that report
-- "localhost" (iOS), where the MagicDNS label is the useful one.
local function displayName(p)
  local host = p.HostName or ""
  local label = (p.DNSName or ""):match("^([^.]+)") or ""
  if host == "" or host == "localhost" then return label ~= "" and label or host end
  return host
end

local function osGlyph(os)
  os = (os or ""):lower()
  if os == "macos" then return "device-laptop" end
  if os == "ios" then return "device-mobile" end
  if os == "android" then return "device-mobile" end
  if os == "windows" then return "device-desktop" end
  if os == "linux" then return "server" end
  return "devices"
end

-- status JSON -> {
--   state, self = { name, ip, dns }, user, tailnet,
--   exit = peer or nil, exits = { peer... }, peers = { peer... }
-- } with peer = { id, name, ip, dns, os, glyph, online, isExit, shared }
function Common.summarize(d)
  local s = {
    state = d.BackendState or "Unknown",
    tailnet = d.CurrentTailnet and d.CurrentTailnet.Name or nil,
    suffix = d.MagicDNSSuffix or "",
    exits = {},
    peers = {},
  }
  local me = d.Self or {}
  s.self = { name = displayName(me), ip = me.TailscaleIPs and me.TailscaleIPs[1] or nil, dns = me.DNSName }
  if d.User and me.UserID then
    local u = d.User[tostring(me.UserID)]
    s.user = u and (u.LoginName or u.DisplayName) or nil
  end
  for id, p in pairs(d.Peer or {}) do
    local dns = (p.DNSName or ""):gsub("%.$", "")
    local peer = {
      id = id,
      name = displayName(p),
      ip = p.TailscaleIPs and p.TailscaleIPs[1] or nil,
      dns = dns,
      os = p.OS or "",
      glyph = osGlyph(p.OS),
      online = p.Online == true,
      isExit = p.ExitNode == true,
      -- shared in from another tailnet (Mac app files these separately)
      shared = s.suffix ~= "" and dns:sub(-#s.suffix) ~= s.suffix,
    }
    s.peers[#s.peers + 1] = peer
    if p.ExitNodeOption then s.exits[#s.exits + 1] = peer end
    if peer.isExit then s.exit = peer end
  end
  local function byName(a, b) return a.name:lower() < b.name:lower() end
  table.sort(s.exits, byName)
  table.sort(s.peers, function(a, b)
    if a.online ~= b.online then return a.online end
    return byName(a, b)
  end)
  return s
end

-- Fetches status and publishes it; cb(summary or nil, error text).
function Common.fetch(cb)
  noctalia.runAsync({ "tailscale", "status", "--json" }, function(res)
    local s, err = nil, nil
    if res.exitCode == 0 or (res.stdout or ""):sub(1, 1) == "{" then
      local d, e = noctalia.json.decode(res.stdout or "")
      if d then s = Common.summarize(d) else err = e or "Couldn't read tailscale status" end
    else
      err = noctalia.string.trim(res.stderr or "")
      if err:find("connect", 1, true) or err == "" then err = "tailscaled isn't running" end
    end
    noctalia.state.set("ts.status", s and {
      state = s.state,
      exit = s.exit and s.exit.name or "",
      self = s.self.name,
      ip = s.self.ip or "",
    } or { state = "Error", exit = "", self = "", ip = "" })
    noctalia.state.set("ts.fetchedAt", noctalia.nowMs())
    cb(s, err)
  end, 5000)
end

return Common
