--- === ScreenAnnotate ===
---
--- Screen annotation overlay for presenting: draw over the screen with the
--- mouse, freeze it, zoom and pan -- all recorded like anything else on screen
--- (unlike native macOS zoom).
---
--- The screen is "live" until it is frozen (a screenshot is taken): the first
--- drag, ctrl+left-click, or the freeze hotkey all freeze it. While frozen you
--- can draw, zoom, and pan on the still image; the apps underneath stay inert.
--- Unfreezing drops the screenshot and goes back to live, without leaving the
--- mode.
---
--- Zoom and drawing both live on the frozen screenshot canvas, so they are drawn
--- into a normal Hammerspoon window. macOS Accessibility zoom is applied by the
--- display compositor *after* screen capture and is invisible to OBS; this one
--- is recorded like anything else on screen. Drawings are anchored to the
--- content, so they zoom and pan along with the frozen screen underneath them.
---
--- ctrl+shift+left-click uses the native macOS zoom instead (live, but not
--- recorded); it needs System Settings > Accessibility > Zoom > "Use keyboard
--- shortcuts to zoom" enabled.
---
--- Mouse controls (while active):
---   left-drag         draw a red pen line   (freezes on first drag)
---   right-drag        draw a yellow marker  (freezes on first drag)
---   shift+drag        draw an arrow      (red on left, yellow on right)
---   cmd+drag          draw a rectangle   (red on left, yellow on right)
---   left/right-click  ripple highlight      (works on the live screen too)
---   ctrl+left-click   freeze + toggle zoom (max <-> normal) at the cursor
---   ctrl+shift+lclick native macOS zoom (live, not recorded by OBS)
---   ctrl+scroll       zoom in / out (clamped between normal and max) at cursor
---   move (zoomed)     pan by holding the cursor at a screen edge (after a beat)
---   ctrl+right-click  clear + unfreeze (or cancel native zoom), stay in the mode
---
--- Keyboard controls are configurable via `:bindHotkeys` (see `defaultHotkeys`):
---   toggle  turn annotation mode on / off          (default ctrl+alt+cmd+P)
---   freeze  toggle freeze (or cancel native zoom)   (default ctrl+F)
---   exit    exit annotation mode                    (default escape)
---
--- Visual and behavioural tunables live in `ScreenAnnotate.config`; override any
--- field after `hs.loadSpoon("ScreenAnnotate")` and before `:start()`.
---
--- Download: https://github.com/thedenische/ScreenAnnotate.spoon

-- `hs` (and `spoon`) are injected by the Hammerspoon runtime; see .luarc.json
-- for the lua-language-server global declarations.

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "ScreenAnnotate"
obj.version = "1.0.0"
obj.author = "Denis Che <the.denis.che@gmail.com>"
obj.homepage = "https://github.com/thedenische/ScreenAnnotate.spoon"
obj.license = "MIT - https://opensource.org/licenses/MIT"

-- Default hotkeys. Override any subset via `:bindHotkeys`; missing actions fall
-- back to these. `toggle` is global; `freeze` and `exit` are active only while
-- annotation mode is on.
obj.defaultHotkeys = {
    toggle = { { "ctrl", "alt", "cmd" }, "p" },
    freeze = { { "ctrl" }, "f" },
    exit   = { {}, "escape" },
}

-- User-tunable config. Override individual fields after loading the Spoon, e.g.
--   spoon.ScreenAnnotate.config.zoom.max = 2.0
--   spoon.ScreenAnnotate.config.pen.color = { red = 0, green = 1, blue = 0, alpha = 1 }
obj.config = {
    -- Freehand pen (left button) and marker (right button): colour + thickness.
    pen    = { color = { red = 1, green = 0.2, blue = 0.2, alpha = 1 }, width = 4 },
    marker = { color = { red = 1, green = 0.9, blue = 0.1, alpha = 0.35 }, width = 16 },
    -- Arrow / rectangle stroke width (kept crisp regardless of pen/marker width).
    shapeWidth = 4,
    -- Arrowhead length as a multiple of the (zoom-adjusted) line width, and the
    -- arrowhead half-angle in degrees.
    arrowHeadRatio = 4.5,
    arrowWingDeg = 28,
    -- Click ripple (highlight) animation.
    ripple = {
        color = { red = 1, green = 0.85, blue = 0.1, alpha = 1 },
        radiusFrom = 8,
        radiusTo = 45,
        ringWidth = 4,
        duration = 0.4, -- seconds
    },
    -- Zoom: max magnification, ctrl+scroll increment, transition duration.
    zoom = { max = 1.75, step = 0.15, anim = 0.16 },
    -- Edge pan: px from the edge that triggers panning, delay before it engages,
    -- and px moved per tick while panning.
    pan = { edge = 2, delay = 0.22, speed = 36 },
    -- Frame rate for the ripple / zoom / pan animations.
    fps = 60,
    -- Min px of movement before a press counts as a drag (jitter guard).
    dragThreshold = 3,
}

-- Live reference to the active config; re-synced in :start() so replacing the
-- whole table (not just fields) is also honoured.
local config = obj.config

local types = hs.eventtap.event.types
local FULL_FRAME = { x = "0%", y = "0%", w = "100%", h = "100%" } -- whole canvas

-- Frozen-canvas element slots: the screenshot image, the click-capturing fill,
-- then one element per drawing (added from FIRST_DRAWING onward).
local IMG, FILL, FIRST_DRAWING = 1, 2, 3

-- Near-invisible fill alpha: still captures clicks, but is effectively unseen.
local CAPTURE_ALPHA = 0.001
-- macOS Accessibility zoom toggle ({ mods, key }).
local NATIVE_ZOOM_KEY = { { "alt", "cmd" }, "8" }

-- ---------------------------------------------------------------------------
-- Pure geometry helpers. These take `frame` / `view` explicitly and touch no
-- Spoon state, so they can be unit-tested with plain Lua (exposed as
-- `ScreenAnnotate._geom`). `frame` is the canvas frame in screen coords; `view`
-- is { scale, tx, ty } mapping content coords -> canvas-local coords via
-- screenLocal = scale*content + (tx, ty).
-- ---------------------------------------------------------------------------
local geom = {}
obj._geom = geom

-- Absolute screen point -> canvas-local coords (identity when frame is nil).
function geom.toLocal(frame, pos)
    return frame and { x = pos.x - frame.x, y = pos.y - frame.y } or pos
end

-- Absolute screen point -> content coords (undoing the current zoom / pan).
function geom.toContent(frame, view, pos)
    local l = geom.toLocal(frame, pos)
    return { x = (l.x - view.tx) / view.scale, y = (l.y - view.ty) / view.scale }
end

-- Keep the view within the content: at scale s the magnified image is s*w by
-- s*h, so the offset stays in [w*(1-s), 0] (and likewise for y) to avoid showing
-- empty space past the edges.
function geom.clampOffset(frame, scale, tx, ty)
    local minTx, minTy = frame.w * (1 - scale), frame.h * (1 - scale)
    return math.max(minTx, math.min(0, tx)), math.max(minTy, math.min(0, ty))
end

-- Offset that keeps the content point under `anchorScreen` fixed at `scale`
-- (i.e. zoom around the cursor), clamped to the content.
function geom.zoomOffset(frame, view, scale, anchorScreen)
    local l = geom.toLocal(frame, anchorScreen)
    local cx, cy = (l.x - view.tx) / view.scale, (l.y - view.ty) / view.scale
    return geom.clampOffset(frame, scale, l.x - scale * cx, l.y - scale * cy)
end

-- Arrow as one open polyline: shaft a->b, then back out to each wing tip.
-- `headLen` is the arrowhead length; `wing` its half-angle in radians.
function geom.arrowPolyline(a, b, headLen, wing)
    local ang = math.atan(b.y - a.y, b.x - a.x)
    local function head(s)
        return { x = b.x - headLen * math.cos(ang + s), y = b.y - headLen * math.sin(ang + s) }
    end
    return { a, b, head(wing), b, head(-wing) }
end

-- Axis-aligned rectangle frame from two opposite corners.
function geom.rectFrame(a, b)
    return {
        x = math.min(a.x, b.x), y = math.min(a.y, b.y),
        w = math.abs(b.x - a.x), h = math.abs(b.y - a.y),
    }
end

-- The affine transform mapping content coords -> canvas-local coords for `view`.
-- (Depends on hs.canvas.matrix, so it lives outside the pure `geom` table.)
local function viewMatrix(view)
    return hs.canvas.matrix.identity():translate(view.tx, view.ty):scale(view.scale)
end

-- ---------------------------------------------------------------------------
-- Runtime state (single mutable table, reset by clear() / stop()).
-- ---------------------------------------------------------------------------
local state = {
    active = false,
    canvas = nil,        -- frozen-screen drawing surface (nil while live)
    frame = nil,         -- canvas frame in screen coords (for local conversion)
    stroke = nil,        -- in-progress stroke, or nil
    tap = nil,           -- mouse event tap (nil while inactive)
    hotkeys = nil,       -- mode-scoped hotkeys (rebuilt from the bound spec on start)
    view = { scale = 1, tx = 0, ty = 0 }, -- identity (scale 1, no offset) => not zoomed
    panTimer = nil,
    panEdgeSince = nil,  -- when the cursor first reached an edge (for pan.delay)
    zoomTimer = nil,     -- runs a smooth zoom transition, or nil
    nativeZoom = false,  -- did *we* switch native macOS zoom on?
}

-- Forward declarations (referenced by config / handlers before they're defined).
local stop, clear
local freeze, zoomToggle, unfreezeStep

-- Native macOS Accessibility zoom (⌥⌘8 toggle). We track whether *we* switched
-- it on so freeze / clear / exit can turn it back off reliably -- blindly
-- re-sending the toggle would zoom back in when it is already off.
local function nativeZoomToggle()
    hs.eventtap.keyStroke(NATIVE_ZOOM_KEY[1], NATIVE_ZOOM_KEY[2])
    state.nativeZoom = not state.nativeZoom
end

-- Switch native zoom off if we turned it on; returns true when it did something.
local function nativeUnzoom()
    if not state.nativeZoom then return false end
    nativeZoomToggle()
    return true
end

-- Per-button config. `style` selects the pen/marker colour + width from config.
-- `ctrl` is the action for a ctrl+click (no drawing); plain drags draw the
-- freehand pen/marker, modified drags draw shapes (see MODS).
local BUTTONS = {
    left = {
        down = types.leftMouseDown,
        drag = types.leftMouseDragged,
        up = types.leftMouseUp,
        style = "pen",
        -- Already zoomed? Either click just unzooms the current zoom, without
        -- switching kind (the two zooms never stack). Otherwise engage the
        -- requested kind: ctrl+shift = native macOS zoom (live, not recorded,
        -- dropping any freeze first); ctrl alone = software freeze + zoom.
        ctrl = function(flags)
            if state.nativeZoom then nativeUnzoom() return end
            if state.canvas and state.view.scale > 1 then zoomToggle() return end
            if flags.shift then
                clear()
                nativeZoomToggle()
            else
                if freeze() then zoomToggle() end
            end
        end,
    },
    right = {
        down = types.rightMouseDown,
        drag = types.rightMouseDragged,
        up = types.rightMouseUp,
        style = "marker",
        ctrl = function() unfreezeStep() end, -- unzoom first, then clear + unfreeze
    },
}

-- Modifier held during a drag -> stroke kind (see KINDS). Checked in order, so
-- if several are held the first listed wins. Same for both buttons.
local MODS = {
    { mod = "shift", kind = "arrow" },
    { mod = "cmd", kind = "rect" },
}

-- Stop a timer if it is running; returns nil for easy reassignment.
local function stopTimer(timer)
    if timer then timer:stop() end
    return nil
end

-- Drive step(p) each frame with progress p in [0, 1] over `duration` seconds,
-- ending exactly on p = 1, then call `done` (if given). Returns the timer.
local function animate(duration, step, done)
    local t0 = hs.timer.secondsSinceEpoch()
    local timer
    timer = hs.timer.doEvery(1 / config.fps, function()
        local p = math.min((hs.timer.secondsSinceEpoch() - t0) / duration, 1)
        step(p)
        if p >= 1 then
            timer:stop()
            if done then done() end
        end
    end)
    return timer
end

-- A copy of `color` with a replaced alpha (RGB kept).
local function withAlpha(color, a)
    return { red = color.red, green = color.green, blue = color.blue, alpha = a }
end

-- Animated ripple highlight at an absolute screen point.
local function ripple(pos)
    local r = config.ripple
    local size = (r.radiusTo + r.ringWidth) * 2
    local c = hs.canvas.new({ x = pos.x - size / 2, y = pos.y - size / 2, w = size, h = size }):show()
    c:level(hs.canvas.windowLevels.cursor)
    c:canvasMouseEvents(false, false, false, false)
    c[1] = {
        type = "circle",
        action = "stroke",
        strokeColor = r.color,
        strokeWidth = r.ringWidth,
        center = { x = size / 2, y = size / 2 },
        radius = r.radiusFrom,
    }
    animate(r.duration, function(p)
        c[1].radius = r.radiusFrom + (r.radiusTo - r.radiusFrom) * p
        c[1].strokeColor = withAlpha(r.color, 1 - p)
    end, function() c:delete() end)
end

-- Re-apply the current view transform to the screenshot and every drawing so
-- they move and scale together (the click-capturing fill is left untransformed).
local function applyView()
    local canvas = state.canvas
    if not canvas then return end
    local m = viewMatrix(state.view)
    canvas[IMG].transformation = m    -- screenshot image
    for i = FIRST_DRAWING, #canvas do -- drawings (FILL is the click-capturing fill)
        canvas[i].transformation = m
    end
end

-- A stroked polyline element (shared by freehand pen and the arrow).
local function lineElement(coords, color, width)
    return {
        type = "segments",
        coordinates = coords,
        action = "stroke",
        strokeColor = color,
        strokeWidth = width,
        strokeCapStyle = "round",
        strokeJoinStyle = "round",
    }
end

-- Stroke kinds. `shape` strokes keep just two anchors (press + cursor) and are
-- redrawn each move; freehand accumulates every point. `render(points, color,
-- width)` returns the canvas element. Shapes use config.shapeWidth so they stay
-- crisp regardless of the button's freehand pen/marker thickness; they inherit
-- the button's colour (so they are opaque on the left, translucent on the right).
local KINDS = {
    freehand = {
        render = function(pts, color, width) return lineElement(pts, color, width) end,
    },
    arrow = {
        shape = true,
        render = function(pts, color, width)
            local headLen = width * config.arrowHeadRatio -- scales with the (zoom-adjusted) width
            local wing = math.rad(config.arrowWingDeg)    -- half-angle of the arrowhead
            return lineElement(geom.arrowPolyline(pts[1], pts[2], headLen, wing), color, width)
        end,
    },
    rect = {
        shape = true,
        render = function(pts, color, width)
            return {
                type = "rectangle",
                action = "stroke",
                strokeColor = color,
                strokeWidth = width,
                frame = geom.rectFrame(pts[1], pts[2]),
            }
        end,
    },
}

-- Render the in-progress stroke into its own canvas element (slot created
-- lazily, then mutated in place on each new point). Points and width are in
-- content space, so the shared view transform scales the stroke thickness along
-- with the zoom: lines drawn while zoomed in are proportionally fatter.
local function drawCurrent()
    local stroke, canvas = state.stroke, state.canvas
    if not (canvas and stroke and stroke.points and #stroke.points >= 2) then return end
    stroke.idx = stroke.idx or math.max(#canvas + 1, FIRST_DRAWING)
    local el = stroke.kind.render(stroke.points, stroke.color, stroke.width)
    el.transformation = viewMatrix(state.view)
    canvas[stroke.idx] = el
end

-- Stroke lifecycle (content coordinates). One drawing path for every drag,
-- whether it is the first (which freezes) or a later one on the frozen screen.
local function strokeBegin(btn, kind, screenPress)
    -- The first point is added on the first drag move (once the canvas, and so
    -- the coordinate frame, exists). Remember the press, pen and kind until then.
    local style = config[btn.style]
    local width = kind.shape and config.shapeWidth or style.width
    state.stroke = { press = screenPress, color = style.color, width = width, kind = kind }
end

local function strokeExtend(screenPos)
    local stroke = state.stroke
    if not stroke then return end
    if not stroke.points then
        stroke.points = { geom.toContent(state.frame, state.view, stroke.press) } -- seed from the press point
    end
    local p = geom.toContent(state.frame, state.view, screenPos)
    if stroke.kind.shape then
        stroke.points[2] = p -- shapes track just the moving end-anchor
    else
        stroke.points[#stroke.points + 1] = p
    end
    drawCurrent()
end

local function strokeEnd()
    state.stroke = nil
end

-- Freeze the screen: snapshot + a click-capturing canvas. Returns success.
freeze = function()
    if state.canvas then return true end
    nativeUnzoom() -- never freeze underneath native zoom (that would double up)

    -- Freeze the screen the cursor is on (not just the focused one), so drawing
    -- on a secondary display works; fall back to the main screen if unknown.
    local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local shot = screen:snapshot() -- before the canvas exists, so it's not captured
    if not shot then
        hs.alert.show("Could not take a screenshot. Check Screen Recording permission for Hammerspoon.")
        return false
    end

    state.view.scale, state.view.tx, state.view.ty = 1, 0, 0 -- fresh freeze starts unzoomed
    state.frame = screen:fullFrame()
    local canvas = hs.canvas.new(state.frame):show()
    canvas:level(hs.canvas.windowLevels.cursor)
    canvas[IMG] = { type = "image", image = shot, imageScaling = "scaleToFit", frame = FULL_FRAME }
    -- Near-transparent fill captures clicks so the apps underneath stay inert.
    -- The canvas only blocks the apps; drawing itself is driven by the event tap
    -- (the canvas mouse callback does not fire during drags).
    canvas[FILL] = { type = "rectangle", action = "fill", fillColor = { white = 0, alpha = CAPTURE_ALPHA }, frame = FULL_FRAME }
    canvas:canvasMouseEvents(true, true, false, false)
    canvas:mouseCallback(function() end) -- required, else clicks pass through
    state.canvas = canvas
    return true
end

-- Edge-pan tick: while zoomed, pan when the cursor sits right at a screen edge.
-- Panning only engages after the cursor has held the edge for pan.delay, so a
-- brush past the edge during a presentation doesn't shift the view.
local function panTick()
    local view, frame = state.view, state.frame
    local dx, dy = 0, 0
    if state.canvas and view.scale > 1 and not (state.stroke and state.stroke.points) then
        local edge, speed = config.pan.edge, config.pan.speed
        local m = hs.mouse.absolutePosition()
        local lx, ly = m.x - frame.x, m.y - frame.y
        if lx <= edge then dx = speed elseif lx >= frame.w - edge then dx = -speed end
        if ly <= edge then dy = speed elseif ly >= frame.h - edge then dy = -speed end
    end
    if dx == 0 and dy == 0 then
        state.panEdgeSince = nil
        return
    end
    local now = hs.timer.secondsSinceEpoch()
    state.panEdgeSince = state.panEdgeSince or now
    if now - state.panEdgeSince < config.pan.delay then return end -- wait out the delay first
    view.tx, view.ty = geom.clampOffset(frame, view.scale, view.tx + dx, view.ty + dy)
    applyView()
end

-- Run the edge-pan timer only while zoomed in.
local function updatePan()
    if state.canvas and state.view.scale > 1 then
        state.panTimer = state.panTimer or hs.timer.doEvery(1 / config.fps, panTick)
    else
        state.panTimer = stopTimer(state.panTimer)
        state.panEdgeSince = nil
    end
end

-- Smoothly move the view to a target (scale + offset) with an ease in/out.
-- `onDone` (optional) runs once the transition finishes.
local function animateView(scale, tx, ty, onDone)
    state.zoomTimer = stopTimer(state.zoomTimer)
    local view = state.view
    local s0, tx0, ty0 = view.scale, view.tx, view.ty
    if scale == s0 and tx == tx0 and ty == ty0 then
        if onDone then onDone() end
        return
    end
    state.zoomTimer = animate(config.zoom.anim, function(p)
        local e = p * p * (3 - 2 * p) -- smoothstep easing
        view.scale = s0 + (scale - s0) * e
        view.tx = tx0 + (tx - tx0) * e
        view.ty = ty0 + (ty - ty0) * e
        applyView()
    end, function()
        state.zoomTimer = nil
        updatePan()
        if onDone then onDone() end
    end)
end

-- Set the zoom level, keeping the content point under `anchorScreen` fixed so
-- zooming happens around the cursor. Clamped to [1, zoom.max], animated smoothly.
local function setZoom(scale, anchorScreen, onDone)
    if not state.canvas then return end
    scale = math.max(1, math.min(config.zoom.max, scale))
    local tx, ty = geom.zoomOffset(state.frame, state.view, scale, anchorScreen)
    animateView(scale, tx, ty, onDone)
end

-- ctrl+left-click: jump to max zoom, or back to normal if already zoomed in.
zoomToggle = function()
    setZoom(state.view.scale > 1 and 1 or config.zoom.max, hs.mouse.absolutePosition())
end

-- ctrl+scroll: step the zoom in / out around the cursor.
local function zoomBy(delta)
    if not state.canvas then return end
    setZoom(state.view.scale + delta, hs.mouse.absolutePosition())
end

-- Clear drawings and unfreeze back to the live screen (stays active).
clear = function()
    state.panTimer = stopTimer(state.panTimer)
    state.zoomTimer = stopTimer(state.zoomTimer)
    state.panEdgeSince = nil
    state.view.scale, state.view.tx, state.view.ty = 1, 0, 0
    if state.canvas then
        state.canvas:delete()
        state.canvas = nil
    end
    state.frame = nil
    state.stroke = nil
end

-- Unfreeze in one press: cancel native zoom if it's on; else if the software
-- zoom is in, smoothly zoom back out and then clear + unfreeze; otherwise clear.
unfreezeStep = function()
    if nativeUnzoom() then return end
    if state.canvas and state.view.scale > 1 then
        setZoom(1, hs.mouse.absolutePosition(), clear)
    else
        clear()
    end
end

-- Toggle freeze without drawing: cancel native zoom if it's on; else freeze to
-- make plain clicks inert, or step back out (unzoom, then unfreeze).
local function toggleFreeze()
    if nativeUnzoom() then return end
    if not state.canvas then freeze() else unfreezeStep() end
end

-- Mouse-down: begin a stroke (kind chosen by held modifier), or run ctrl.
local function onDown(btn, flags)
    if flags.ctrl then
        btn.ctrl(flags)
        return true -- consume so it doesn't reach the app underneath
    end
    local kind = KINDS.freehand
    for _, m in ipairs(MODS) do
        if flags[m.mod] then kind = KINDS[m.kind] break end
    end
    strokeBegin(btn, kind, hs.mouse.absolutePosition())
    return false
end

-- Mouse-drag: freeze on the first real movement, then extend the stroke. Works
-- the same for later strokes on an already-frozen screen.
local function onDrag()
    local stroke = state.stroke
    if not stroke then return end
    local cur = hs.mouse.absolutePosition()
    if not state.canvas then
        local dx, dy = cur.x - stroke.press.x, cur.y - stroke.press.y
        local threshold = config.dragThreshold * config.dragThreshold
        if dx * dx + dy * dy < threshold then return end -- ignore jitter
        if not freeze() then return end
    end
    strokeExtend(cur)
end

-- Mouse-up: a drawn stroke stays; a click without a drag ripples instead.
local function onUp()
    local stroke = state.stroke
    if stroke and not stroke.points then ripple(stroke.press) end
    strokeEnd()
end

-- Single event tap dispatching every mouse event by button + phase. Returning
-- false keeps the OS emitting the drag stream needed to draw; the frozen canvas
-- blocks the apps underneath on its own.
local scrollDeltaAxis1 = hs.eventtap.event.properties.scrollWheelEventDeltaAxis1
local function handle(event)
    local t = event:getType()
    local flags = event:getFlags()

    -- ctrl+scroll zooms in / out around the cursor (only on the frozen screen).
    if t == types.scrollWheel then
        if state.canvas and flags.ctrl then
            local d = event:getProperty(scrollDeltaAxis1)
            if d ~= 0 then zoomBy(d > 0 and config.zoom.step or -config.zoom.step) end
            return true
        end
        return false
    end

    for _, btn in pairs(BUTTONS) do
        if t == btn.down then return onDown(btn, flags) end
        if t == btn.drag then onDrag() return false end
        if t == btn.up then onUp() return false end
    end
    return false
end

-- Resolve a hotkey spec ({ mods, key }) for `action` from the bound mapping,
-- falling back to the default.
local function hotkeySpec(action)
    local map = obj._hotkeys or {}
    return map[action] or obj.defaultHotkeys[action]
end

local function start()
    if state.active then return end
    state.active = true
    config = obj.config -- honour a wholesale config replacement

    local events = { types.scrollWheel }
    for _, btn in pairs(BUTTONS) do
        events[#events + 1] = btn.down
        events[#events + 1] = btn.drag
        events[#events + 1] = btn.up
    end
    state.tap = hs.eventtap.new(events, handle):start()

    -- Mode-scoped hotkeys, rebuilt from the current spec so :bindHotkeys changes
    -- take effect on the next start.
    local exitSpec, freezeSpec = hotkeySpec("exit"), hotkeySpec("freeze")
    state.hotkeys = {
        hs.hotkey.new(exitSpec[1], exitSpec[2], stop),
        hs.hotkey.new(freezeSpec[1], freezeSpec[2], toggleFreeze),
    }
    for _, k in ipairs(state.hotkeys) do k:enable() end
end

stop = function()
    if not state.active then return end
    state.active = false
    nativeUnzoom() -- don't leave the screen zoomed after exiting
    if state.tap then state.tap:stop() end
    if state.hotkeys then
        -- Delete (not just disable) so repeated on/off cycles don't accumulate
        -- stale entries in Hammerspoon's global hotkey registry.
        for _, k in ipairs(state.hotkeys) do k:delete() end
        state.hotkeys = nil
    end
    clear()
end

--- ScreenAnnotate:start() -> self
--- Method
--- Start annotation mode (same as triggering the `toggle` hotkey while off).
function obj:start()
    start()
    return self
end

--- ScreenAnnotate:stop() -> self
--- Method
--- Stop annotation mode, clearing any freeze / drawings / zoom.
function obj:stop()
    stop()
    return self
end

--- ScreenAnnotate:toggle() -> self
--- Method
--- Toggle annotation mode on / off.
function obj:toggle()
    if state.active then stop() else start() end
    return self
end

--- ScreenAnnotate:bindHotkeys(mapping) -> self
--- Method
--- Binds hotkeys for ScreenAnnotate.
---
--- Parameters:
---  * mapping - A table with any of the keys `toggle`, `freeze`, `exit`, each a
---    `{ mods, key }` pair (e.g. `{ {"ctrl","alt","cmd"}, "w" }`). Missing keys
---    fall back to `ScreenAnnotate.defaultHotkeys`. `toggle` is a global hotkey;
---    `freeze` and `exit` are active only while annotation mode is on.
---
--- Returns:
---  * The ScreenAnnotate object
function obj:bindHotkeys(mapping)
    self._hotkeys = mapping or {}

    -- The global toggle. Rebind cleanly if called more than once.
    if self._toggleHotkey then self._toggleHotkey:delete() end
    local toggleSpec = hotkeySpec("toggle")
    self._toggleHotkey = hs.hotkey.bind(toggleSpec[1], toggleSpec[2], function()
        self:toggle()
    end)

    -- freeze / exit are (re)built on the next start from the stored spec.
    return self
end

return obj
