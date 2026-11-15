--[[
glide-circle-test.lua - check offline that M_Glide.lua draws a selection circle where it draws the body.

What it does: loads a hook file with stand-in EEex functions (nothing from the game or EEex runs),
walks one creature a step and calls the mod's two drawing routines, Glide_Hook_OnMarker for the
selection circle and Glide_Hook_OnRender for the body, at chosen times. It checks:
  standing still        circle and body are at the real position
  circle glides         after a step the circle is between the old and the new position, then arrives
  same as body          in one redraw the circle and the body are shifted by the same amount,
                        whichever of the two is drawn first
  rounding edge         also when the glide crosses a half pixel between the two draws of one redraw
  slow redraw           also when the two draws of one redraw are several thousandths of a second apart
  next redraw moves     the following redraw gets a new place, not the previous one again
  far jump              a jump longer than the mod glides (teleport) is shown at once
  pause, circle eases   paused in mid-glide, the circle takes half a second to reach the real
                        position while the body arrives at once (the settings the file starts with)
  pause, body eases     with BODY_EASES_ON_PAUSE set to true the body moves with the circle
  pause, no easing      with CIRCLE_EASES_ON_PAUSE set to false the circle arrives at once
  pause ends early      when the game goes on before the half second is over, the circle does not jump
  circles off           with CIRCLES_GLIDE set to false the circle is at the real position, the body glides
  only the picture      the creature's real position is never written
Prints one line per check (PASS or FAIL and what was seen); exits with 1 when any check fails.

Run (Lua 5.2, e.g. the Ubuntu package lua5.2):
  lua5.2 glide-circle-test.lua HOOK.lua
--]]

-- Simulated memory with the byte patterns M_Glide.lua searches for. Every EEex label is at ANCHOR.
local ANCHOR = 0x1000
local BEFORE = {0x48,0x8B,0x46,0x0C,0x48,0x8D,0x56,0x0C,0x44,0x0F,0xB6,0x46,0x28,0x48,0x8B,0x4E,0x18,0x48,0x89,0x45,0x90}
local AFTER = {0x8B,0x55,0x94,0x4C,0x8B,0x4E,0x18,0x03,0xD0,0x89,0x55,0x94,0x41,0x8B,0x81,0x44,0x02,0x00,0x00}
local CALL_SIZE = 5
local BEFORE_AT = ANCHOR + 0x100
local AFTER_AT = BEFORE_AT + #BEFORE + CALL_SIZE
local MARKER_CALL = {0x48,0x8D,0x8E,0xC8,0x4B,0x00,0x00,0x4C,0x8B,0xC6,0x49,0x8B,0xD6,0xE8}
local MARKER_HOOK = {
	0x4C,0x8B,0x47,0x18,0x4C,0x8D,0x4F,0x0C,0x89,0x4C,0x24,0x28,0x49,0x81,0xC0,
	0xC8,0x05,0x00,0x00,0x89,0x54,0x24,0x20,0x48,0x8B,0xCB,0x49,0x8B,0xD7,0xE8,
}
local MARKER_CALL_AT = ANCHOR + 0x10
local CALL_DISTANCE_SIZE = 4
local MARKER_FUNCTION_AT = 0x4000
local MARKER_HOOK_OFFSET = 0xAA

local FRAME_POINTER = 0x9000                -- the body's drawing function keeps its position copy below it
local LOCAL_X, LOCAL_Y = FRAME_POINTER - 0x70, FRAME_POINTER - 0x6C
local POINT = 0xA000                        -- what the stand-in EEex_Malloc returns: the circle's position
local POINT_Y = 4

local STEP_PX = 7                 -- one walking step
local GLIDE_US = 66667            -- the glide length the mod starts with (START_GUESS_US in M_Glide.lua)
local DRAW_US = 6944              -- one redraw at 144 per second
local WITHIN_REDRAW_US = 100      -- between the two draws of one creature in one redraw
local SLOW_REDRAW_US = 4300       -- the same under load; the largest seen in a crowded hall was 4215
local BEFORE_HALF_PIXEL_US = 4700 -- the glide of STEP_PX reaches half a pixel 4762 microseconds after its start
local START_Y = 300
local FAR_PX = 500                -- longer than the mod glides (MAX_GLIDE_DISTANCE in M_Glide.lua)
local EASE_MS = 500               -- the glide-in time the pause checks set (GLIDE_IN_MS in M_Glide.lua)
local DEFAULT_EASE_MS = 60        -- GLIDE_IN_MS as shipped in M_Glide.lua
local US_PER_MS = 1000
local EASE_US = EASE_MS * US_PER_MS
local LONG_EASE_MS = 1000         -- a longer glide-in time set at the top of the file
local PAUSE_AFTER_US = 2 * DRAW_US -- the pause begins this long after the step: the picture is 6 px behind
local LAG_AT_PAUSE = -6
local SHORT_PAUSE_US = 100000

local function place(mem, at, bytes)
	for i, b in ipairs(bytes) do mem[at + i - 1] = b end
end

-- A fresh game state with the hook file loaded. settings: values for the true/false and number settings at the
-- top of the hook file, by name; the file's own text is changed before it is loaded.
local function newGame(hookPath, settings)
	local mem = {}
	place(mem, BEFORE_AT, BEFORE)
	place(mem, AFTER_AT, AFTER)
	place(mem, MARKER_CALL_AT, MARKER_CALL)
	local distanceAt = MARKER_CALL_AT + #MARKER_CALL
	mem[distanceAt] = MARKER_FUNCTION_AT - (distanceAt + CALL_DISTANCE_SIZE)   -- the stand-in EEex_Read32 returns it whole
	place(mem, MARKER_FUNCTION_AT + MARKER_HOOK_OFFSET, MARKER_HOOK)
	local game = {mem = mem, now = 0, positionWrites = 0}
	local env = {
		EEex_Active = true,
		EEex_TryLabel = function() return ANCHOR end,
		EEex_ReadU8 = function(a) return mem[a] or 0 end,
		EEex_Read32 = function(a) return mem[a] or 0 end,
		EEex_Write32 = function(a, v) mem[a] = v end,
		EEex_Malloc = function() return POINT end,
		EEex_Utility_GetMicroseconds = function() return game.now end,
		EEex_DisableCodeProtection = function() end,
		EEex_EnableCodeProtection = function() end,
		EEex_HookIntegrityWatchdogRegister = {},
		EEex_FlattenTable = function(t) return t end,
		EEex_GenLuaCall = function() return {} end,
		EEex_HookBeforeRestoreWithLabels = function() end,
		EEex_HookAfterRestoreWithLabels = function() end,
		EngineGlobals = {g_pBaldurChitin = {m_pEngineWorld = {m_bPaused = 0}}},
	}
	game.env = setmetatable(env, {__index = _G})
	local file = assert(io.open(hookPath, "r"))
	local source = file:read("*a")
	file:close()
	for name, value in pairs(settings or {}) do
		local changed
		source, changed = source:gsub("local " .. name .. " = %w+", "local " .. name .. " = " .. tostring(value), 1)
		assert(changed == 1, "setting " .. name .. " not found in " .. hookPath)
	end
	assert(load(source, "@" .. hookPath, "t", game.env))()
	-- the creature: its real position may be read, and every write to it is counted
	local position = {x = 0, y = START_Y}
	game.position = position
	game.sprite = {m_id = 1, m_pos = setmetatable({}, {
		__index = position,
		__newindex = function() game.positionWrites = game.positionWrites + 1 end,
	})}
	return game
end

-- One draw of the selection circle at a time; returns how far it is drawn from the real position.
local function drawCircle(game, at)
	game.now = at
	game.env.Glide_Hook_OnMarker(game.sprite, POINT)
	return game.mem[POINT] - game.position.x, game.mem[POINT + POINT_Y] - game.position.y
end

-- One draw of the body at a time; returns how far the mod moved the drawing function's position copy.
local function drawBody(game, at)
	game.now = at
	game.mem[LOCAL_X], game.mem[LOCAL_Y] = game.position.x, game.position.y
	game.env.Glide_Hook_OnRender(game.sprite, FRAME_POINTER)
	return game.mem[LOCAL_X] - game.position.x, game.mem[LOCAL_Y] - game.position.y
end

-- A game in which the creature has just taken one step to the right, noticed by a draw of `first`
-- (drawCircle or drawBody) at the returned time.
local function afterOneStep(hookPath, first, settings)
	local game = newGame(hookPath, settings)
	first(game, 0)
	game.position.x = STEP_PX
	local stepAt = GLIDE_US
	first(game, stepAt)
	return game, stepAt
end

-- shortcut: Lua has no argument parser in its standard library; the tool takes one positional argument.
local hookPath = arg[1]
assert(hookPath and #arg == 1, "usage: lua5.2 glide-circle-test.lua HOOK.lua")

local failures = 0
local function report(name, pass, detail)
	if not pass then failures = failures + 1 end
	print(string.format("%-4s %-20s %s", pass and "PASS" or "FAIL", name, detail))
end

do
	local game = newGame(hookPath)
	local cx, cy = drawCircle(game, 0)
	local bx, by = drawBody(game, WITHIN_REDRAW_US)
	local cx2, cy2 = drawCircle(game, DRAW_US)
	report("standing still", cx == 0 and cy == 0 and bx == 0 and by == 0 and cx2 == 0 and cy2 == 0,
		string.format("circle %d,%d body %d,%d circle next redraw %d,%d", cx, cy, bx, by, cx2, cy2))
end

do
	local game, stepAt = afterOneStep(hookPath, drawCircle)
	local midX, midY = drawCircle(game, stepAt + GLIDE_US / 2)
	local endX, endY = drawCircle(game, stepAt + GLIDE_US + DRAW_US)
	report("circle glides", midX < 0 and midX > -STEP_PX and midY == 0 and endX == 0 and endY == 0,
		string.format("half-way %d,%d (step %d px), after the glide %d,%d", midX, midY, STEP_PX, endX, endY))
end

for _, order in ipairs({{"circle first", drawCircle, drawBody}, {"body first", drawBody, drawCircle}}) do
	local name, first, second = order[1], order[2], order[3]
	local game, stepAt = afterOneStep(hookPath, first)
	local same, shown = true, {}
	for redraw = 1, 12 do
		local at = stepAt + redraw * DRAW_US
		local ax, ay = first(game, at)
		local bx, by = second(game, at + WITHIN_REDRAW_US)
		if ax ~= bx or ay ~= by then same = false end
		shown[#shown + 1] = string.format("%d/%d", ax, bx)
	end
	report("same as body", same, name .. ": " .. table.concat(shown, " "))
end

do
	local game, stepAt = afterOneStep(hookPath, drawCircle)
	local cx = drawCircle(game, stepAt + BEFORE_HALF_PIXEL_US)
	local bx = drawBody(game, stepAt + BEFORE_HALF_PIXEL_US + WITHIN_REDRAW_US)
	local alone = afterOneStep(hookPath, drawBody)
	local lateX = drawBody(alone, stepAt + BEFORE_HALF_PIXEL_US + WITHIN_REDRAW_US)
	report("rounding edge", cx == bx and lateX ~= cx,
		string.format("circle %d, body %d; a body drawn alone at the body's time %d", cx, bx, lateX))
end

do
	local game, stepAt = afterOneStep(hookPath, drawCircle)
	local cx = drawCircle(game, stepAt + BEFORE_HALF_PIXEL_US)
	local bx = drawBody(game, stepAt + BEFORE_HALF_PIXEL_US + SLOW_REDRAW_US)
	report("slow redraw", cx == bx, string.format("circle %d, body %d, drawn %d microseconds later", cx, bx, SLOW_REDRAW_US))
end

do
	local game, stepAt = afterOneStep(hookPath, drawCircle)
	local firstX = drawCircle(game, stepAt + 2 * DRAW_US)
	drawBody(game, stepAt + 2 * DRAW_US + WITHIN_REDRAW_US)
	local nextX = drawCircle(game, stepAt + 3 * DRAW_US)
	report("next redraw moves", nextX > firstX, string.format("%d, then %d", firstX, nextX))
end

do
	local game = newGame(hookPath)
	drawCircle(game, 0)
	game.position.x = FAR_PX
	local cx, cy = drawCircle(game, GLIDE_US)
	local bx, by = drawBody(game, GLIDE_US + WITHIN_REDRAW_US)
	report("far jump", cx == 0 and cy == 0 and bx == 0 and by == 0,
		string.format("circle %d,%d body %d,%d from the real position", cx, cy, bx, by))
end

do
	local game, stepAt = afterOneStep(hookPath, drawCircle)
	for redraw = 1, 12 do
		drawCircle(game, stepAt + redraw * DRAW_US)
		drawBody(game, stepAt + redraw * DRAW_US + WITHIN_REDRAW_US)
	end
	report("only the picture", game.positionWrites == 0,
		string.format("writes to the creature's real position: %d", game.positionWrites))
end

local function setPaused(game, value)
	game.env.EngineGlobals.g_pBaldurChitin.m_pEngineWorld.m_bPaused = value and 1 or 0
end

-- A game paused in mid-glide; both pictures have been drawn once in the pause. Returns the game
-- and the time the pause began.
local function pausedInGlide(hookPath, settings)
	settings = settings or {}
	if settings.GLIDE_IN_MS == nil then settings.GLIDE_IN_MS = EASE_MS end
	local game, stepAt = afterOneStep(hookPath, drawCircle, settings)
	local pauseAt = stepAt + PAUSE_AFTER_US
	setPaused(game, true)
	local cx = drawCircle(game, pauseAt)
	local bx = drawBody(game, pauseAt + WITHIN_REDRAW_US)
	return game, pauseAt, cx, bx
end

-- Draws both pictures at a time; returns how far the circle and the body are from the real position.
local function drawBoth(game, at)
	local cx = drawCircle(game, at)
	local bx = drawBody(game, at + WITHIN_REDRAW_US)
	return cx, bx
end

do
	local game, pauseAt, c0, b0 = pausedInGlide(hookPath)
	local cHalf, bHalf = drawBoth(game, pauseAt + EASE_US / 2)
	local cEnd, bEnd = drawBoth(game, pauseAt + EASE_US + DRAW_US)
	report("pause, circle eases", c0 == LAG_AT_PAUSE and b0 == LAG_AT_PAUSE and cHalf == LAG_AT_PAUSE / 2 and bHalf == 0
		and cEnd == 0 and bEnd == 0,
		string.format("circle/body at the pause %d/%d, after a quarter second %d/%d, after half a second %d/%d",
			c0, b0, cHalf, bHalf, cEnd, bEnd))
end

do
	local game, pauseAt = pausedInGlide(hookPath, {BODY_EASES_ON_PAUSE = true})
	local cHalf, bHalf = drawBoth(game, pauseAt + EASE_US / 2)
	local cEnd, bEnd = drawBoth(game, pauseAt + EASE_US + DRAW_US)
	report("pause, body eases", cHalf == LAG_AT_PAUSE / 2 and bHalf == cHalf and cEnd == 0 and bEnd == 0,
		string.format("circle/body after a quarter second %d/%d, after half a second %d/%d", cHalf, bHalf, cEnd, bEnd))
end

do
	local game, pauseAt = pausedInGlide(hookPath, {CIRCLE_EASES_ON_PAUSE = false})
	local cHalf, bHalf = drawBoth(game, pauseAt + EASE_US / 2)
	report("pause, no easing", cHalf == 0 and bHalf == 0,
		string.format("circle/body after a quarter second %d/%d", cHalf, bHalf))
end

do
	local game, pauseAt = pausedInGlide(hookPath)
	local cBefore = drawCircle(game, pauseAt + SHORT_PAUSE_US)
	setPaused(game, false)
	local cAfter = drawCircle(game, pauseAt + SHORT_PAUSE_US + DRAW_US)
	local cEnd = drawCircle(game, pauseAt + EASE_US + DRAW_US)
	report("pause ends early", cBefore < 0 and cAfter >= cBefore and cAfter - cBefore <= 1 and cEnd == 0,
		string.format("circle before the game goes on %d, one redraw after %d, after half a second %d", cBefore, cAfter, cEnd))
end

do
	local game, stepAt = afterOneStep(hookPath, drawBody, {CIRCLES_GLIDE = false})
	local cx = drawCircle(game, stepAt + PAUSE_AFTER_US)
	local bx = drawBody(game, stepAt + PAUSE_AFTER_US + WITHIN_REDRAW_US)
	report("circles off", cx == 0 and bx == LAG_AT_PAUSE, string.format("circle %d, body %d", cx, bx))
end

do
	local game, pauseAt = pausedInGlide(hookPath, {GLIDE_IN_MS = LONG_EASE_MS})
	local longUs = LONG_EASE_MS * US_PER_MS
	local cHalf = drawCircle(game, pauseAt + longUs / 2)
	local cOld = drawCircle(game, pauseAt + EASE_US + DRAW_US)
	local cEnd = drawCircle(game, pauseAt + longUs + DRAW_US)
	report("glide-in 1000 ms", cHalf == LAG_AT_PAUSE / 2 and cOld < 0 and cEnd == 0,
		string.format("circle after half a second %d, just after half a second %d, after a second %d", cHalf, cOld, cEnd))
end

do
	local game, pauseAt = pausedInGlide(hookPath, {GLIDE_IN_MS = DEFAULT_EASE_MS, CIRCLES_GLIDE = true})
	local defaultUs = DEFAULT_EASE_MS * US_PER_MS
	local cHalf = drawCircle(game, pauseAt + defaultUs / 2)
	local cEnd = drawCircle(game, pauseAt + defaultUs + DRAW_US)
	report("glide-in as shipped", cHalf < 0 and cEnd == 0,
		string.format("%d ms: circle after half of it %d, just after it %d", DEFAULT_EASE_MS, cHalf, cEnd))
end

do
	local game, pauseAt = pausedInGlide(hookPath, {GLIDE_IN_MS = 0})
	local cHalf, bHalf = drawBoth(game, pauseAt + EASE_US / 2)
	report("glide-in 0 ms", cHalf == 0 and bHalf == 0,
		string.format("circle/body after a quarter second %d/%d", cHalf, bHalf))
end

print(string.format("%d failure(s)", failures))
os.exit(failures == 0 and 0 or 1)
