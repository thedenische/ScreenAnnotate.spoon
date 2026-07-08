-- Plain-Lua unit tests for ScreenAnnotate._geom (the pure geometry helpers).
--
-- These exercise the state-free math with no Hammerspoon dependency: we stub the
-- handful of `hs.*` fields init.lua reads at load time, then assert against known
-- values. Run from the Spoon root:
--
--   lua spec/geom_spec.lua      # Lua 5.3+ (Hammerspoon bundles 5.4)
--   luajit spec/geom_spec.lua   # LuaJIT (a two-arg math.atan shim is added below)

-- LuaJIT / Lua 5.1 lack two-arg math.atan; init.lua uses math.atan(y, x) (5.3+).
-- Shim it via math.atan2 so the tests run under either runtime.
do
    local twoArgOk = pcall(function()
        assert(math.abs(math.atan(1, 1) - 0.7853981633974483) < 1e-9)
    end)
    if not twoArgOk and math.atan2 then
        local atan = math.atan
        math.atan = function(y, x) if x then return math.atan2(y, x) else return atan(y) end end
    end
end

-- Minimal load-time stubs for the globals init.lua touches at require time.
_G.hs = {
    eventtap = {
        event = {
            types = {},
            properties = { scrollWheelEventDeltaAxis1 = "scrollWheelEventDeltaAxis1" },
        },
    },
}

-- Locate init.lua relative to this spec file.
local here = (arg and arg[0] or ""):match("(.*/)") or "./"
local obj = dofile(here .. "../init.lua")
local geom = assert(obj._geom, "ScreenAnnotate._geom is not exposed")

-- --- tiny test harness ------------------------------------------------------
local passed, failed = 0, 0
local function approx(a, b) return math.abs(a - b) < 1e-9 end
local function check(name, cond)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("  FAIL: " .. name)
    end
end
local function checkPoint(name, p, x, y)
    check(name, approx(p.x, x) and approx(p.y, y))
end

-- --- toLocal ----------------------------------------------------------------
checkPoint("toLocal: identity when frame is nil", geom.toLocal(nil, { x = 5, y = 7 }), 5, 7)
checkPoint("toLocal: subtracts frame origin", geom.toLocal({ x = 100, y = 50 }, { x = 130, y = 80 }), 30, 30)

-- --- toContent (undo zoom + pan) --------------------------------------------
do
    local frame = { x = 100, y = 100, w = 800, h = 600 }
    local view = { scale = 2, tx = -50, ty = -20 }
    -- screenLocal = scale*content + (tx,ty); pick content (40, 60):
    -- local = (2*40-50, 2*60-20) = (30, 100); screen = local + frame origin.
    local screen = { x = 100 + 30, y = 100 + 100 }
    checkPoint("toContent: inverts scale+offset", geom.toContent(frame, view, screen), 40, 60)
end
checkPoint("toContent: identity view is a passthrough (local)",
    geom.toContent({ x = 0, y = 0, w = 10, h = 10 }, { scale = 1, tx = 0, ty = 0 }, { x = 3, y = 4 }), 3, 4)

-- --- clampOffset ------------------------------------------------------------
do
    local frame = { w = 800, h = 600 }
    local tx, ty = geom.clampOffset(frame, 2, 100, 100)
    check("clampOffset: positive offset clamps to 0", approx(tx, 0) and approx(ty, 0))
    -- min offset at scale 2 is w*(1-2) = -800, h*(1-2) = -600.
    tx, ty = geom.clampOffset(frame, 2, -5000, -5000)
    check("clampOffset: over-pan clamps to content edge", approx(tx, -800) and approx(ty, -600))
    tx, ty = geom.clampOffset(frame, 2, -300, -200)
    check("clampOffset: in-range offset is unchanged", approx(tx, -300) and approx(ty, -200))
end

-- --- zoomOffset (keep content under the cursor fixed) -----------------------
do
    local frame = { x = 0, y = 0, w = 800, h = 600 }
    local view = { scale = 1, tx = 0, ty = 0 }
    local anchor = { x = 400, y = 300 } -- screen centre
    local tx, ty = geom.zoomOffset(frame, view, 2, anchor)
    -- content under the anchor is (400,300); after zoom it must map back to (400,300):
    -- 2*400 + tx = 400 -> tx = -400 (then clamped, still within [-800,0]).
    check("zoomOffset: keeps the anchor point fixed", approx(tx, -400) and approx(ty, -300))
    -- Re-deriving the content point from the new view must return the anchor.
    local back = geom.toContent(frame, { scale = 2, tx = tx, ty = ty }, anchor)
    checkPoint("zoomOffset: round-trips the anchor content", back, 400, 300)
end

-- --- arrowPolyline ----------------------------------------------------------
do
    -- Horizontal a->b along +x; wings sit symmetrically behind the tip.
    local a, b = { x = 0, y = 0 }, { x = 100, y = 0 }
    local poly = geom.arrowPolyline(a, b, 10, math.rad(30))
    check("arrowPolyline: 5 vertices (a,b,wing,b,wing)", #poly == 5)
    checkPoint("arrowPolyline: starts at a", poly[1], 0, 0)
    checkPoint("arrowPolyline: reaches b", poly[2], 100, 0)
    checkPoint("arrowPolyline: returns to b before 2nd wing", poly[4], 100, 0)
    -- wing at +angle: b - headLen*(cos30, sin30) = (100 - 8.6603, -5)
    checkPoint("arrowPolyline: first wing tip", poly[3], 100 - 10 * math.cos(math.rad(30)), -10 * math.sin(math.rad(30)))
    checkPoint("arrowPolyline: second wing tip mirrors", poly[5], 100 - 10 * math.cos(math.rad(30)), 10 * math.sin(math.rad(30)))
end

-- --- rectFrame --------------------------------------------------------------
checkPoint("rectFrame: origin is the min corner",
    geom.rectFrame({ x = 30, y = 40 }, { x = 10, y = 90 }), 10, 40)
do
    local r = geom.rectFrame({ x = 30, y = 40 }, { x = 10, y = 90 })
    check("rectFrame: width/height are absolute", approx(r.w, 20) and approx(r.h, 50))
end

-- --- summary ----------------------------------------------------------------
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
