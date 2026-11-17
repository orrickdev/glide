--[[
M_Glide.lua - smooth creature movement for Baldur's Gate II: Enhanced Edition.

Walking creatures and their selection circles glide between the game's movement steps instead of
jumping from step to step. Only the picture moves; positions in the game are never changed.
When the game is paused, a picture that is still on its way can glide into place over a set time.

Built for: Baldur's Gate II: Enhanced Edition 2.7.3.0,
with EEex, started through InfinityLoader. Without EEex this file does nothing.

Install: copy this file into the game's override folder. Remove: delete it.
On/off: EEex Options, tab "Glide". EEex saves the settings in the game's settings file.
--]]

if Glide_Installed then return end   -- never hook twice

-- The settings as they are until the player changes them in EEex Options. A change made there is
-- saved and from then on wins over these lines.
local CIRCLES_GLIDE = true            -- selection circles glide with the bodies
local CIRCLE_EASES_ON_PAUSE = true    -- when the game is paused, a circle moves slowly to the real position
local BODY_EASES_ON_PAUSE = false     -- when the game is paused, a body moves slowly to the real position
local GLIDE_IN_MS = 60                -- how long that slow move takes, in milliseconds (0 to 5000)

local REQUIRED = {
	{"EEex_TryLabel", EEex_TryLabel}, {"EEex_ReadU8", EEex_ReadU8}, {"EEex_Read32", EEex_Read32},
	{"EEex_Write32", EEex_Write32}, {"EEex_Utility_GetMicroseconds", EEex_Utility_GetMicroseconds},
	{"EEex_DisableCodeProtection", EEex_DisableCodeProtection},
	{"EEex_EnableCodeProtection", EEex_EnableCodeProtection},
	{"EEex_HookBeforeRestoreWithLabels", EEex_HookBeforeRestoreWithLabels},
	{"EEex_HookAfterRestoreWithLabels", EEex_HookAfterRestoreWithLabels}, {"EEex_Malloc", EEex_Malloc},
	{"EEex_FlattenTable", EEex_FlattenTable}, {"EEex_GenLuaCall", EEex_GenLuaCall},
	{"EEex_HookIntegrityWatchdogRegister", EEex_HookIntegrityWatchdogRegister},
}

local function refuse(reason)
	error("[Glide] not installed: " .. reason
		.. ". The game runs without smooth movement. M_Glide.lua is built for BG2:EE 2.7.3.0 with EEex.", 0)
end

local missing = nil
for _, required in ipairs(REQUIRED) do
	if required[2] == nil then missing = required[1]; break end
end
if missing ~= nil then
	if not EEex_Active then return end         -- no EEex: do nothing
	refuse("EEex function " .. missing .. " not found")
end

-- Finding the hook point of the body
local ANCHOR_LABEL = "Hook-CGameSprite::Render()-B3Invis"
local SEARCH_LENGTH = 0x1300      -- bytes searched after the anchor; covers the rest of the function
local AFTER_CALL = {
	0x8B, 0x55, 0x94, 0x4C, 0x8B, 0x4E, 0x18, 0x03, 0xD0, 0x89,
	0x55, 0x94, 0x41, 0x8B, 0x81, 0x44, 0x02, 0x00, 0x00,
}
local BEFORE_CALL = {
	0x48, 0x8B, 0x46, 0x0C, 0x48, 0x8D, 0x56, 0x0C, 0x44, 0x0F,
	0xB6, 0x46, 0x28, 0x48, 0x8B, 0x4E, 0x18, 0x48, 0x89, 0x45, 0x90,
}
local CALL_SIZE = 5                                     -- the call between the two patterns
local BEFORE_CALL_GAP = #BEFORE_CALL + CALL_SIZE        -- from BEFORE_CALL start to AFTER_CALL start
local HOOK_OFFSET = 12                                  -- from AFTER_CALL start to the hooked mov
local HOOK_SIZE = 7                                     -- length of the hooked mov

-- Where the drawing function keeps its copy of the position
local LOCAL_X = -0x70
local LOCAL_Y = -0x6C

-- Finding the hook point of the selection circle. The function that decides whether a circle is
-- shown calls the function that draws it; the hook point is inside the called function.
local MARKER_ANCHOR_LABEL = "Hook-CGameSprite::RenderMarkers()-B3Invis1"
local MARKER_SEARCH_LENGTH = 0x430   -- bytes searched after the anchor; covers the rest of the function
local MARKER_CALL = {                -- the instructions before the call, and the call's first byte
	0x48, 0x8D, 0x8E, 0xC8, 0x4B, 0x00, 0x00, 0x4C, 0x8B, 0xC6, 0x49, 0x8B, 0xD6, 0xE8,
}
local CALL_DISTANCE_SIZE = 4         -- bytes of a call's signed distance to its target
local SIGN_32 = 0x80000000           -- distances from here up are negative
local RANGE_32 = 0x100000000
local MARKER_HOOK_OFFSET = 0xAA      -- from the start of the called function to the hook point
local MARKER_HOOK = {                -- from the hook point to the call that draws the circle
	0x4C, 0x8B, 0x47, 0x18, 0x4C, 0x8D, 0x4F, 0x0C, 0x89, 0x4C, 0x24, 0x28, 0x49, 0x81, 0xC0,
	0xC8, 0x05, 0x00, 0x00, 0x89, 0x54, 0x24, 0x20, 0x48, 0x8B, 0xCB, 0x49, 0x8B, 0xD7, 0xE8,
}
local MARKER_HOOK_SIZE = 8           -- the two hooked instructions; the second takes the position's address

-- The position handed to the circle's drawing function: two 32-bit numbers, x then y
local POINT_SIZE = 8
local POINT_Y = 4

-- Gliding
local US_PER_SECOND = 1000000
local US_PER_MS = 1000
local GLIDE_IN_MAX_MS = 5000      -- the longest glide-in time the options menu accepts
local easeUs = GLIDE_IN_MS * US_PER_MS -- on pause, the slow move to the real position takes this long
local PAUSE_US = 200000           -- a longer gap between changes: the creature stood still; start over
local MAX_GLIDE_DISTANCE = 64     -- pixels; a bigger jump (teleport, new area) is shown at once

local function bytesMatch(address, bytes)
	for i, byte in ipairs(bytes) do
		if EEex_ReadU8(address + i - 1) ~= byte then return false end
	end
	return true
end

local function findHookAddress()
	local anchor = EEex_TryLabel(ANCHOR_LABEL)
	if anchor == nil then return nil, "EEex label " .. ANCHOR_LABEL .. " not found" end
	local found = nil
	for address = anchor, anchor + SEARCH_LENGTH - #AFTER_CALL do
		if bytesMatch(address, AFTER_CALL) then
			if found ~= nil then return nil, "byte pattern found twice" end
			found = address
		end
	end
	if found == nil then return nil, "byte pattern not found" end
	if not bytesMatch(found - BEFORE_CALL_GAP, BEFORE_CALL) then
		return nil, "second byte pattern does not match"
	end
	return found + HOOK_OFFSET
end

local function findMarkerHookAddress()
	local anchor = EEex_TryLabel(MARKER_ANCHOR_LABEL)
	if anchor == nil then return nil, "EEex label " .. MARKER_ANCHOR_LABEL .. " not found" end
	local call = nil
	for address = anchor, anchor + MARKER_SEARCH_LENGTH - #MARKER_CALL do
		if bytesMatch(address, MARKER_CALL) then call = address; break end
	end
	if call == nil then return nil, "call that draws the selection circle not found" end
	local distanceAddress = call + #MARKER_CALL
	local distance = EEex_Read32(distanceAddress)
	if distance >= SIGN_32 then distance = distance - RANGE_32 end
	local address = distanceAddress + CALL_DISTANCE_SIZE + distance + MARKER_HOOK_OFFSET
	if not bytesMatch(address, MARKER_HOOK) then
		return nil, "byte pattern of the selection circle does not match"
	end
	return address
end

local function round(value)
	return math.floor(value + 0.5)
end

local function addToLocal(address, delta)
	if delta ~= 0 then EEex_Write32(address, EEex_Read32(address) + delta) end
end

-- One glide state per creature, keyed by the game's object id
-- Fields of a state s:
--   fromX, fromY, toX, toY, stepStart: the picture moves from (fromX, fromY) to the real position
--     (toX, toY) during glideUs microseconds, starting at stepStart; glideUs nil = real position shown
--   lastChange: time of the last change of m_pos;  gaps: the last gaps, newest first
--   lastGlideUs: the last glide duration used, kept across stops;  lastSeen: time of the last draw
--   pairAt, pairFor: the time one picture of the creature was worked out for, and which picture
--     (BODY or CIRCLE), until the creature's other picture has used that time too
--   ease: while a slow move on pause is under way, how far the picture was from the real position
--     when the pause began (x, y) and when that was (start);  easedPause: the pause it belongs to
local states = {}
local enabled = true              -- the player's on/off switch, set at the end of the file
local circlesGlide = CIRCLES_GLIDE

local function glideFraction(s, now)
	if s.glideUs == nil then return 1 end
	return math.min((now - s.stepStart) / s.glideUs, 1)
end

local GAP_HISTORY = 2
local OUTLIER_FACTOR = 1.5        -- two gaps further apart than this are not averaged

-- Mean of the last two gaps; when one is more than OUTLIER_FACTOR times the other, the shorter one.
local function glideDuration(gaps)
	local short, long = math.min(gaps[1], gaps[2]), math.max(gaps[1], gaps[2])
	if long > short * OUTLIER_FACTOR then return short end
	return (short + long) / 2
end

local START_GUESS_US = 66667     -- two game ticks at 30 per second, the normal walking pace;

local function startStep(s, now, x, y)
	local gap = s.lastChange and now - s.lastChange
	local far = math.abs(x - s.toX) > MAX_GLIDE_DISTANCE or math.abs(y - s.toY) > MAX_GLIDE_DISTANCE
	if far then
		s.gaps = {}
	elseif gap == nil or gap > PAUSE_US then
		s.gaps = {s.lastGlideUs or START_GUESS_US}
	else
		table.insert(s.gaps, 1, gap)
		s.gaps[GAP_HISTORY + 1] = nil
	end
	if #s.gaps == 0 then
		s.fromX, s.fromY, s.glideUs = x, y, nil    -- shown at once
	else
		-- start the new glide where the picture is now, so it never jumps
		local f = glideFraction(s, now)
		s.fromX, s.fromY = s.fromX + f * (s.toX - s.fromX), s.fromY + f * (s.toY - s.fromY)
		s.glideUs = #s.gaps >= GAP_HISTORY and glideDuration(s.gaps) or s.gaps[1]
		s.lastGlideUs = s.glideUs
	end
	s.toX, s.toY, s.stepStart, s.lastChange = x, y, now, now
end

-- Forgetting: once per SWEEP_INTERVAL_US, states not drawn for FORGET_US are dropped
local SWEEP_INTERVAL_US = US_PER_SECOND
local FORGET_US = 3 * US_PER_SECOND
local sweepStart = nil

local function sweep(now)
	for id, s in pairs(states) do
		if now - s.lastSeen > FORGET_US then
			states[id] = nil                       -- removing the current key during pairs is allowed in Lua
		end
	end
end

local function newState(x, y, now)
	return {
		fromX = x, fromY = y, toX = x, toY = y, stepStart = now,
		lastChange = nil, gaps = {}, glideUs = nil, lastGlideUs = nil, lastSeen = now,
		pairAt = now, pairFor = nil, ease = nil, easedPause = nil,
	}
end

-- A creature has two pictures: its body and its selection circle
local BODY, CIRCLE = "body", "circle"
local easesOnPause = {[BODY] = BODY_EASES_ON_PAUSE, [CIRCLE] = CIRCLE_EASES_ON_PAUSE}

-- In one screen redraw the game draws a creature's selection circle and its body one after the
-- other. Both are worked out for the moment of the first, so they never part by a rounding step.
local PAIR_US = 50000             -- the two draws of one redraw are never this far apart

local function redrawTime(s, now, picture)
	if s.pairFor ~= nil and s.pairFor ~= picture and now - s.pairAt < PAIR_US then
		s.pairFor = nil
		return s.pairAt
	end
	s.pairFor, s.pairAt = picture, now
	return now
end

-- Whether the game is paused, read from the game at most once per PAUSE_CHECK_US.
local PAUSE_CHECK_US = 1000
local paused = false
local pauseCount = 0              -- pauses seen so far; tells one pause from the next
local pauseCheckedAt = nil
local pauseReadable = true        -- false once reading the game's pause state has failed

local function readPaused()
	return EngineGlobals.g_pBaldurChitin.m_pEngineWorld.m_bPaused ~= 0
end

local function gamePaused(now)
	if not pauseReadable then return false end
	if pauseCheckedAt == nil or now - pauseCheckedAt >= PAUSE_CHECK_US then
		local readable, value = pcall(readPaused)
		if not readable then
			pauseReadable = false
			return false
		end
		if value and not paused then pauseCount = pauseCount + 1 end
		paused, pauseCheckedAt = value, now
	end
	return paused
end

-- Where a creature's picture belongs at this moment, then its real position: four numbers.
local function picturePosition(sprite, now, picture)
	local id = sprite.m_id
	local x, y = sprite.m_pos.x, sprite.m_pos.y
	local s = states[id]
	if s == nil then
		states[id] = newState(x, y, now)
		return x, y, x, y
	end
	s.lastSeen = now
	local moved = x ~= s.toX or y ~= s.toY
	if not moved and s.glideUs == nil and s.ease == nil then
		return x, y, x, y                          -- standing still: the real position
	end
	local at = redrawTime(s, now, picture)
	if moved then startStep(s, at, x, y) end
	local glideX, glideY = x, y
	if s.glideUs ~= nil then
		local f = glideFraction(s, at)
		if f >= 1 then s.glideUs = nil end         -- glide finished
		glideX = round(s.fromX + f * (s.toX - s.fromX))
		glideY = round(s.fromY + f * (s.toY - s.fromY))
	end

	-- When a pause begins while the picture is on its way, the rest of the way takes easeUs.
	-- If the game goes on before that, what is left of the way keeps shrinking on top of the glide.
	local isPaused = gamePaused(at)
	if isPaused and s.easedPause ~= pauseCount then
		s.easedPause = pauseCount
		if glideX ~= x or glideY ~= y then
			s.ease = {x = glideX - x, y = glideY - y, start = at}
		end
	end
	local ease = s.ease
	if ease ~= nil then
		local left = 0                           -- a glide-in time of 0: arrive at once
		if easeUs > 0 then left = 1 - (at - ease.start) / easeUs end
		if left <= 0 then
			s.ease = nil
		elseif easesOnPause[picture] then
			local baseX, baseY = glideX, glideY
			if isPaused then baseX, baseY = x, y end
			return round(baseX + left * ease.x), round(baseY + left * ease.y), x, y
		end
	end
	return glideX, glideY, x, y
end

-- Called by the body hook for every creature the game draws. Moves the drawing function's copy of
-- the position to where the picture belongs.
function Glide_Hook_OnRender(sprite, framePointer)
	if not enabled then return end
	local now = EEex_Utility_GetMicroseconds()
	local shownX, shownY, x, y = picturePosition(sprite, now, BODY)
	addToLocal(framePointer + LOCAL_X, shownX - x)
	addToLocal(framePointer + LOCAL_Y, shownY - y)
	if sweepStart == nil then
		sweepStart = now
	elseif now - sweepStart >= SWEEP_INTERVAL_US then
		sweep(now)
		sweepStart = now
	end
end

-- Called by the circle hook for every selection circle the game draws. Writes where the circle
-- belongs into the two numbers at point; the game draws the circle there.
function Glide_Hook_OnMarker(sprite, point)
	local x, y
	if enabled and circlesGlide then
		x, y = picturePosition(sprite, EEex_Utility_GetMicroseconds(), CIRCLE)
	else
		x, y = sprite.m_pos.x, sprite.m_pos.y
	end
	EEex_Write32(point, x)
	EEex_Write32(point + POINT_Y, y)
end

local hookAddress, problem = findHookAddress()
if hookAddress == nil then refuse(problem) end
local markerHookAddress, markerProblem = findMarkerHookAddress()
if markerHookAddress == nil then refuse(markerProblem) end

local markerPoint = EEex_Malloc(POINT_SIZE)

EEex_DisableCodeProtection()

-- Shadow space must stay 80 (32 saved registers + 48 for two Lua arguments); less crashes the game.
EEex_HookBeforeRestoreWithLabels(hookAddress, 0, HOOK_SIZE, HOOK_SIZE, {
	{"hook_integrity_watchdog_ignore_registers", {
		EEex_HookIntegrityWatchdogRegister.RAX, EEex_HookIntegrityWatchdogRegister.RDX,
		EEex_HookIntegrityWatchdogRegister.R10, EEex_HookIntegrityWatchdogRegister.R11,
	}}},
	EEex_FlattenTable({
		{[[
			#MAKE_SHADOW_SPACE(80)
			mov qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-8)], rcx
			mov qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-16)], rdx
			mov qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-24)], r8
			mov qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-32)], r9
		]]},
		EEex_GenLuaCall("Glide_Hook_OnRender", {
			["args"] = {
				function(rspOffset) return {"mov qword ptr ss:[rsp+#$(1)], rsi #ENDL", {rspOffset}}, "CGameSprite" end,
				function(rspOffset) return {"mov qword ptr ss:[rsp+#$(1)], rbp #ENDL", {rspOffset}} end,
			},
		}),
		{[[
			call_error:
			mov r9, qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-32)]
			mov r8, qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-24)]
			mov rdx, qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-16)]
			mov rcx, qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-8)]
			mov edx, dword ptr ss:[rbp-0x6C]
			#DESTROY_SHADOW_SPACE
		]]},
	})
)

-- The circle hook runs after the two hooked instructions, the second of which put the address of
-- the creature's position into r9. It points r9 at markerPoint, which Glide_Hook_OnMarker has
-- filled; if the Lua call fails, r9 gets the creature's position again.
-- Shadow space 72 = 24 for three saved registers + 48 for two Lua arguments.
EEex_HookAfterRestoreWithLabels(markerHookAddress, 0, MARKER_HOOK_SIZE, MARKER_HOOK_SIZE, {
	{"hook_integrity_watchdog_ignore_registers", {
		EEex_HookIntegrityWatchdogRegister.RAX, EEex_HookIntegrityWatchdogRegister.R9,
		EEex_HookIntegrityWatchdogRegister.R10, EEex_HookIntegrityWatchdogRegister.R11,
	}}},
	EEex_FlattenTable({
		{[[
			#MAKE_SHADOW_SPACE(72)
			mov qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-8)], rcx
			mov qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-16)], rdx
			mov qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-24)], r8
		]]},
		EEex_GenLuaCall("Glide_Hook_OnMarker", {
			["args"] = {
				function(rspOffset) return {"mov qword ptr ss:[rsp+#$(1)], rdi #ENDL", {rspOffset}}, "CGameSprite" end,
				function(rspOffset) return {[[
					mov rax, #$(1) #ENDL
					mov qword ptr ss:[rsp+#$(2)], rax #ENDL
				]], {markerPoint, rspOffset}} end,
			},
		}),
		{[[
			mov r9, #$(1) ]], {markerPoint}, [[ #ENDL
			jmp registers_back

			call_error:
			lea r9, qword ptr ds:[rdi+0xC]

			registers_back:
			mov r8, qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-24)]
			mov rdx, qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-16)]
			mov rcx, qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-8)]
			#DESTROY_SHADOW_SPACE
		]]},
	})
)

EEex_EnableCodeProtection()

Glide_Installed = true

-- The player's "On/Off" switch, for other files of the mod (M_GlideV.lua glides the view only while it is on).
function Glide_IsEnabled()
	return enabled
end

-- Rows other files of the mod add below this file's rows in the "Glide" tab: functions that each return one
-- EEex_Options_DisplayEntry. They are called when EEex builds the tab, after all override files have loaded.
Glide_ExtraOptionEntries = Glide_ExtraOptionEntries or {}

-- The switches, in the EEex Options menu under the tab "Glide".
-- EEex saves each one in the game's settings file, section "Glide". Until the player changes one,
-- smooth movement is on and the others are as set at the top of this file. Without EEex's options
-- functions the mod simply stays as set there.
local OPTION_ENABLED = "Glide_Enabled"
local OPTION_CIRCLES = "Glide_Circles"
local OPTION_CIRCLE_EASE = "Glide_CircleEase"
local OPTION_BODY_EASE = "Glide_BodyEase"
local OPTION_GLIDE_IN_MS = "Glide_GlideInMs"
local GLIDE_IN_DIGITS = 4                 -- characters the time field takes

-- Where EEex saves an option: the game's settings file, this section, under the given name.
local SETTINGS_SECTION = "Glide"
local function saved(name)
	return EEex_Options_NumberLuaStorage.new({ ["section"] = SETTINGS_SECTION, ["key"] = name })
end
local TEXTS = {
	Glide_TabTitle = "Glide",
	Glide_Enabled = "On/Off",
	Glide_Enabled_Description = "Walking creatures glide between the game's movement steps.",
	Glide_Circles = "Selection circles glide",
	Glide_Circles_Description = "A walking creature's selection circle glides with its body. Off: the circle steps with the game.",
	Glide_CircleEase = "Circle: Glide-in on pause",
	Glide_CircleEase_Description = "When the game is paused, a gliding selection circle glides to the creature's real position over the glide-in time.",
	Glide_BodyEase = "Body: Glide-in on pause",
	Glide_BodyEase_Description = "When the game is paused, a gliding body glides to the creature's real position over the glide-in time.",
	Glide_GlideInMs = "Glide-in time on pause (ms)",
	Glide_GlideInMs_Description = "How long, in milliseconds, a circle or body takes to glide into place when the game is paused. 0 to 5000; 0 is the same as both switches above off.",
}

local function optionsAvailable()
	return EEex_Options_Register and EEex_Options_Option and EEex_Options_AddTab
		and EEex_Options_ToggleType and EEex_Options_ClampedAccessor
		and EEex_Options_NumberLuaStorage
		and EEex_Options_DisplayEntry and EEex_Options_ToggleWidget
		and EEex_Menu_AddTranslationLoadedListener and EEex_Options_EditType and EEex_Options_EditWidget
end

-- The game rebuilds its table of interface texts when it loads a language; add ours each time.
local function addTexts()
	if type(uiStrings) ~= "table" then return end
	for key, text in pairs(TEXTS) do uiStrings[key] = text end
end

local function setEnabled(value)
	if value and not enabled then
		states = {}               -- positions seen before the switch are stale; start afresh
		sweepStart = nil
	end
	enabled = value
end

-- The switches below the first one: option name, value until changed, what a change does, saved name.
local SWITCHES = {
	{OPTION_CIRCLES, CIRCLES_GLIDE, function(value) circlesGlide = value end, "Circles Glide"},
	{OPTION_CIRCLE_EASE, CIRCLE_EASES_ON_PAUSE, function(value) easesOnPause[CIRCLE] = value end, "Circle Eases On Pause"},
	{OPTION_BODY_EASE, BODY_EASES_ON_PAUSE, function(value) easesOnPause[BODY] = value end, "Body Eases On Pause"},
}

if optionsAvailable() then
	addTexts()
	EEex_Menu_AddTranslationLoadedListener(addTexts)

	local option = EEex_Options_Register(OPTION_ENABLED, EEex_Options_Option.new({
		["default"]  = 1,
		["type"]     = EEex_Options_ToggleType.new(),
		["accessor"] = EEex_Options_ClampedAccessor.new({ ["min"] = 0, ["max"] = 1 }),
		["storage"]  = saved("Smooth Movement"),
		["onChange"] = function(self) setEnabled((self:get() or 1) ~= 0) end,
	}))
	setEnabled((option:get() or 1) ~= 0)

	for _, switch in ipairs(SWITCHES) do
		local name, atStart, apply, savedName = switch[1], switch[2], switch[3], switch[4]
		EEex_Options_Register(name, EEex_Options_Option.new({
			["default"]  = atStart and 1 or 0,
			["type"]     = EEex_Options_ToggleType.new(),
			["accessor"] = EEex_Options_ClampedAccessor.new({ ["min"] = 0, ["max"] = 1 }),
			["storage"]  = saved(savedName),
			["onChange"] = function(self) apply((self:get() or 0) ~= 0) end,
		}))
	end

	EEex_Options_Register(OPTION_GLIDE_IN_MS, EEex_Options_Option.new({
		["default"]  = GLIDE_IN_MS,
		["type"]     = EEex_Options_EditType.new(),
		["accessor"] = EEex_Options_ClampedAccessor.new({ ["min"] = 0, ["max"] = GLIDE_IN_MAX_MS }),
		["storage"]  = saved("Glide-In Time Ms"),
		["onChange"] = function(self) easeUs = (self:get() or GLIDE_IN_MS) * US_PER_MS end,
	}))

	EEex_Options_AddTab("Glide_TabTitle", function()
		local rows = {
			EEex_Options_DisplayEntry.new({
				["optionID"]    = OPTION_ENABLED,
				["label"]       = "Glide_Enabled",
				["description"] = "Glide_Enabled_Description",
				["widget"]      = EEex_Options_ToggleWidget.new(),
			}),
			EEex_Options_DisplayEntry.new({
				["optionID"]    = OPTION_CIRCLES,
				["label"]       = "Glide_Circles",
				["description"] = "Glide_Circles_Description",
				["widget"]      = EEex_Options_ToggleWidget.new(),
			}),
			EEex_Options_DisplayEntry.new({
				["optionID"]    = OPTION_CIRCLE_EASE,
				["label"]       = "Glide_CircleEase",
				["description"] = "Glide_CircleEase_Description",
				["widget"]      = EEex_Options_ToggleWidget.new(),
			}),
			EEex_Options_DisplayEntry.new({
				["optionID"]    = OPTION_BODY_EASE,
				["label"]       = "Glide_BodyEase",
				["description"] = "Glide_BodyEase_Description",
				["widget"]      = EEex_Options_ToggleWidget.new(),
			}),
			EEex_Options_DisplayEntry.new({
				["optionID"]    = OPTION_GLIDE_IN_MS,
				["label"]       = "Glide_GlideInMs",
				["description"] = "Glide_GlideInMs_Description",
				["widget"]      = EEex_Options_EditWidget.new({
					["maxCharacters"] = GLIDE_IN_DIGITS,
					["number"] = true,
				}),
			}),
		}
		for _, makeRow in ipairs(Glide_ExtraOptionEntries) do
			table.insert(rows, makeRow())
		end
		return { rows }
	end)
end
