--!nonstrict
-- Tailscale bar widget: the dot grid, dimmed while disconnected, with a
-- small lime dot while an exit node carries the traffic (lime, Pond's
-- "connected", not lavender: the notifications bell's unread dot sits one
-- card over in lavender, and this one must not read as a second one).
-- Polls every 10 s and repaints at once when the panel publishes a new
-- `ts.status`.

local Common = require("./common.luau")

local function render()
  local st = noctalia.state.get("ts.status")
  local running = type(st) == "table" and st.state == "Running"
  local exit = running and st.exit ~= "" and st.exit or nil

  local container = barWidget.isVertical() and ui.column or ui.row
  local glyph = ui.glyph({ name = "grid-dots", color = "on_surface" })
  local kids = { glyph }
  if exit then kids[#kids + 1] = ui.box({ width = 5, height = 5, radius = 3, fill = "tertiary" }) end
  barWidget.render(container({ gap = 0, align = "start", opacity = running and 1 or 0.45 }, kids))

  if type(st) ~= "table" then
    barWidget.setTooltip("Tailscale")
  elseif st.state == "Error" then
    barWidget.setTooltip({ { key = "Tailscale", value = "tailscaled isn't running" } })
  elseif not running then
    barWidget.setTooltip({ { key = "Tailscale", value = st.state == "NeedsLogin" and "Logged out" or "Disconnected" } })
  else
    local rows = { { key = "Tailscale", value = "Connected" }, { key = "This device", value = st.ip } }
    rows[#rows + 1] = { key = "Exit node", value = exit or "None" }
    barWidget.setTooltip(rows)
  end
end

noctalia.state.watch("ts.status", function(_value)
  render()
end)

function update()
  noctalia.setUpdateInterval(10000)
  -- one fetch per tick however many bars carry the widget
  local last = noctalia.state.get("ts.fetchedAt")
  if type(last) == "number" and noctalia.nowMs() - last < 9000 then
    render()
    return
  end
  Common.fetch(function() render() end)
end

function onClick()
  noctalia.togglePanel(Common.PANEL)
end

render()
