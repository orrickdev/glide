--[[
M_GlideV.lua - Glide View: smooth view follow for the Glide mod (one machine-code hook). 17 November 2026.

When the view is locked on a creature (cheat key Ctrl+P, the script action LockScroll(), or the Lua console),
the game sets the view at its logic ticks to the creature's real position, so the view moves in steps. This
file keeps the game's lock as it is and smooths the view: on every area redraw, inside the game's
CInfinity::Render after the logic tick of that redraw and before anything is drawn, it moves the view towards
the corner the game set last with a critically damped spring (smooth speed-up and slow-down, no overshoot;
Game Programming Gems 4, ch. 1.10). The spring's time is "Follow Damping"; when the new corner is more than
half a view away (the character was off-screen, e.g. a double-click on a portrait), "Jump Damping" is used
until the view arrives. Both and a "View Damping" switch are in EEex Options, tab "Glide"; M_Glide.lua's "On/Off" switches this too. The view is left where it was set, so mouse clicks match the picture.

It also smooths the follow made by holding a party member's number key: the game then re-centres the view on
the member at every key repeat, setting the corner to the member's real position minus half the view size.
Such a re-centre starts or feeds the same spring; 0.3 s without one ends it. Any other view move (the player
scrolls) ends it at once and is left as it is.

It does nothing while a cutscene runs or the game shakes the screen. Scripts' LockScroll()/UnlockScroll() keep
working, because the lock stays the game's.

Where: EEex itself hooks the screen-shake check in CInfinity::Render (EEex label
"Hook-CInfinity::Render()-HandleScreenShakeJmp"). Every way out of that check reaches the same instruction.
This file finds that instruction through EEex's hook, checks its 12 bytes, and hooks it.
Built for BG2:EE 2.7.3.0 with EEex v1.3.1; on any mismatch it refuses to install and prints why.
Every event is printed with the prefix "[GlideView]". The file name must stay at most 8 characters before ".lua".
--]]

if GlideView_Installed then return end

local SHAKE_LABEL = "Hook-CInfinity::Render()-HandleScreenShakeJmp"
local JMP_REL32 = 0xE9                -- EEex replaced the game's jump with "jmp rel32" to its hook code
local JNE_REL32 = {0x0F, 0x85}        -- the hook code starts with the game's original "jne rel32"
local JNE_SIZE = 6
local JMP_SIZE = 5
-- Where both ways meet (0x1402A06B7 in 2.7.3.0):
--   mov eax,[rbp-0x49] / mov [rbp-0x31],eax / mov eax,[rbp-0x49] / mov [rbp-0x39],eax
local EXPECTED = {0x8B, 0x45, 0xB7, 0x89, 0x45, 0xCF, 0x8B, 0x45, 0xB7, 0x89, 0x45, 0xC7}
local HOOK_SIZE = 6                   -- the first two instructions are moved into the hook

local function log(text)
	print("[GlideView] " .. text)
end

local function refuse(reason)
	log("not installed: " .. reason)
end

local function bytesMatch(address, bytes)
	for i, byte in ipairs(bytes) do
		if EEex_ReadU8(address + i - 1) ~= byte then return false end
	end
	return true
end

local function findHookAddress()
	local label = EEex_TryLabel(SHAKE_LABEL)
	if label == nil then return nil, "EEex label " .. SHAKE_LABEL .. " not found" end
	if EEex_ReadU8(label) ~= JMP_REL32 then return nil, "EEex's screen-shake hook not found at the label" end
	local hookCode = label + JMP_SIZE + EEex_Read32(label + 1)
	if not bytesMatch(hookCode, JNE_REL32) then return nil, "EEex's screen-shake hook code has an unknown layout" end
	local target = hookCode + JNE_SIZE + EEex_Read32(hookCode + #JNE_REL32)
	if not bytesMatch(target, EXPECTED) then return nil, "unknown bytes where the screen-shake check ends" end
	return target
end

local NO_LOCK = -1                -- the world screen's m_scrollLockId when the view follows no creature
local EXACT_SCALE = 10000         -- EEex's exact view coordinates are the view corner times this
local INT_SIZE = 4
local US_PER_SECOND = 1000000
local MS_PER_SECOND = 1000
local FOLLOW_DAMPING_MS = 120     -- settings until the player changes them in EEex Options, tab "Glide"
local JUMP_DAMPING_MS = 300
local MAX_DAMPING_MS = 5000       -- the longest damping the options menu accepts
local DAMPING_DIGITS = 4          -- characters a damping field takes
local FOLLOW_MAX_SPEED = 1000     -- pixels a second the view may reach while following
local JUMP_MAX_SPEED = math.huge  -- a jump is not limited
local MAX_STEP_SECONDS = 0.1      -- a longer gap between redraws (loading, a menu) counts as this

local PARTY_SIZE = 6
local CENTRE_TOLERANCE = 1        -- pixels; the game centres with whole numbers
local KEY_FOLLOW_US = 300000      -- a held key re-centres about 30 times a second; this long without one ends the follow
local followSeconds = FOLLOW_DAMPING_MS / MS_PER_SECOND
local jumpSeconds = JUMP_DAMPING_MS / MS_PER_SECOND
local follow = nil    -- mode ("lock" or "key"), targetX/Y (corner the game set), x/y/velX/velY (spring), setX/setY, at,
                      -- jump (true while gliding to a target that was more than half a view away)
local lastCorner = nil   -- the view corner as the previous redraw left it
local broken = false  -- true once an error stopped the follow

local viewOn = true    -- the player's "View Damping" switch

-- On only while both M_Glide.lua's "On/Off" and this file's "View Damping" are on; without M_Glide.lua,
-- "View Damping" alone decides.
local function isOn()
	return viewOn and (Glide_IsEnabled == nil or Glide_IsEnabled())
end

local function round(value)
	return math.floor(value + 0.5)
end

-- The view corner (x, y) moved into the area's allowed range, the way EEex fits it
local function fitView(infinity, x, y)
	local fitX, fitY
	EEex_RunWithStack(2 * INT_SIZE, function(mem)
		EEex_Write32(mem, x)
		EEex_Write32(mem + INT_SIZE, y)
		infinity:FitViewPosition(EEex_PtrToUD(mem, "Primitive<int>"),
			EEex_PtrToUD(mem + INT_SIZE, "Primitive<int>"), infinity.rViewPort)
		fitX, fitY = EEex_Read32(mem), EEex_Read32(mem + INT_SIZE)
	end)
	return fitX, fitY
end

-- One axis of the spring after dt seconds: new position and speed
local function springAxis(pos, vel, target, dt, seconds, maxSpeed)
	if seconds <= 0 then return target, 0 end   -- damping 0: at once
	local omega = 2 / seconds
	local x = omega * dt
	local decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
	local maxChange = maxSpeed * seconds
	local change = math.max(-maxChange, math.min(maxChange, pos - target))
	local temp = (vel + omega * change) * dt
	local newPos = pos - change + (change + temp) * decay
	if (target - pos > 0) == (newPos > target) then return target, 0 end   -- no overshoot
	return newPos, (vel - omega * temp) * decay
end

-- The party member the game just centred the view on, or nil. When a party member's number key is held,
-- the game sets the view corner to the member's real position minus half the view size (measured in Orrick).
-- The key can be handled before a logic tick in the same redraw, so the member's position as the previous
-- redraw saw it counts as well.
local lastPositions = {}   -- party slot -> {x, y} of the member at the end of the previous redraw

local function centresOn(x, y, halfW, halfH, cornerX, cornerY)
	return math.abs(x - halfW - cornerX) <= CENTRE_TOLERANCE and math.abs(y - halfH - cornerY) <= CENTRE_TOLERANCE
end

local function centredMember(infinity, cornerX, cornerY)
	local port = infinity.rViewPort
	local halfW = math.floor((port.right - port.left) / 2)
	local halfH = math.floor((port.bottom - port.top) / 2)
	for slot = 0, PARTY_SIZE - 1 do
		local member = EEex_Sprite_GetInPortrait(slot)
		if member ~= nil then
			local before = lastPositions[slot]
			if centresOn(member.m_pos.x, member.m_pos.y, halfW, halfH, cornerX, cornerY)
					or (before ~= nil and centresOn(before.x, before.y, halfW, halfH, cornerX, cornerY)) then
				return member
			end
		end
	end
	return nil
end

local function rememberPositions()
	for slot = 0, PARTY_SIZE - 1 do
		local member = EEex_Sprite_GetInPortrait(slot)
		lastPositions[slot] = member ~= nil and {x = member.m_pos.x, y = member.m_pos.y} or nil
	end
end

-- One spring step towards the target, and the view set to the result
local function springView(infinity, now)
	local dt = math.min((now - follow.at) / US_PER_SECOND, MAX_STEP_SECONDS)
	follow.at = now
	local seconds = follow.jump and jumpSeconds or followSeconds
	local maxSpeed = follow.jump and JUMP_MAX_SPEED or FOLLOW_MAX_SPEED
	follow.x, follow.velX = springAxis(follow.x, follow.velX, follow.targetX, dt, seconds, maxSpeed)
	follow.y, follow.velY = springAxis(follow.y, follow.velY, follow.targetY, dt, seconds, maxSpeed)
	local newX, newY = fitView(infinity, round(follow.x), round(follow.y))
	infinity.m_ptCurrentPosExact.x = newX * EXACT_SCALE
	infinity.m_ptCurrentPosExact.y = newY * EXACT_SCALE
	infinity.nNewX, infinity.nNewY = newX, newY
	infinity.m_updateListenPosition = 1
	follow.setX, follow.setY = newX, newY
	if follow.jump and newX == follow.targetX and newY == follow.targetY then follow.jump = false end
end

-- A new target for the spring; more than half a view away from the view makes it a jump
local function setTarget(infinity, x, y)
	follow.targetX, follow.targetY = x, y
	local port = infinity.rViewPort
	if math.abs(x - follow.x) > (port.right - port.left) / 2 or math.abs(y - follow.y) > (port.bottom - port.top) / 2 then
		follow.jump = true
	end
end

local function startFollow(mode, fromX, fromY, toX, toY, now, label)
	follow = {mode = mode, targetX = toX, targetY = toY, x = fromX, y = fromY, velX = 0, velY = 0,
		setX = fromX, setY = fromY, at = now, keyUntil = 0, jump = false}
	print("[GlideView] " .. label)
end

local function inRender(infinityAddress)
	local chitin = EngineGlobals.g_pBaldurChitin
	if not isOn() or chitin:virtual_CutsceneModeActive() ~= 0 then follow = nil; lastCorner = nil; return end
	local area = EEex_Area_GetVisible()
	if area == nil then follow = nil; lastCorner = nil; return end
	local infinity = area.m_cInfinity
	if EEex_UDToPtr(infinity) ~= infinityAddress then return end   -- another view is being drawn
	local cornerX, cornerY = infinity.nNewX, infinity.nNewY
	if infinity.m_bScreenShake ~= 0 then lastCorner = nil; return end   -- the shake moves the view this redraw
	local now = EEex_Utility_GetMicroseconds()
	-- The view was moved by the game since the last redraw (its follow, a party key, a scroll)
	local moved = lastCorner == nil or cornerX ~= lastCorner.x or cornerY ~= lastCorner.y

	local lockId = chitin.m_pEngineWorld.m_scrollLockId
	local locked = nil
	if lockId ~= NO_LOCK then
		locked = EEex_GameObject_Get(lockId)
		if locked ~= nil and not EEex_UDEqual(locked.m_pArea, area) then locked = nil end
	end

	if locked ~= nil then
		-- Lock (Ctrl+P, LockScroll(), console): glide towards every corner the game sets
		if follow == nil or follow.mode ~= "lock" or follow.id ~= lockId then
			startFollow("lock", cornerX, cornerY, cornerX, cornerY, now, "following the lock on id " .. lockId)
			follow.id = lockId
		elseif moved then
			setTarget(infinity, cornerX, cornerY)
		end
		springView(infinity, now)
	else
		if follow ~= nil and follow.mode == "lock" then follow = nil end
		if moved then
			local member = lastCorner ~= nil and centredMember(infinity, cornerX, cornerY) or nil
			if member ~= nil then
				-- A held party key centred the view: glide there from where the view was
				if follow == nil then
					startFollow("key", lastCorner.x, lastCorner.y, lastCorner.x, lastCorner.y, now,
						"following a party key, id " .. member.m_id)
				end
				setTarget(infinity, cornerX, cornerY)
				follow.keyUntil = now + KEY_FOLLOW_US
			elseif follow ~= nil then
				-- Moved some other way (the player scrolls): let go at once
				follow = nil
				print("[GlideView] party key follow ended: the view was moved")
			end
		end
		if follow ~= nil then
			springView(infinity, now)
			local settled = follow.setX == follow.targetX and follow.setY == follow.targetY
			if settled and now > follow.keyUntil then
				follow = nil
				print("[GlideView] party key follow ended")
			end
		end
	end
	lastCorner = {x = infinity.nNewX, y = infinity.nNewY}
	rememberPositions()
end

-- Called by the hook once per area redraw, inside CInfinity::Render, with the address of the view being drawn
GlideView_InRenderCorner = nil   -- for test aids: the corner after this call
function GlideView_Hook_InRender(infinityAddress)
	if not broken then
		local ok, problem = pcall(inRender, infinityAddress)
		if not ok then
			broken = true
			follow = nil
			print("[GlideView] stopped after an error: " .. tostring(problem))
		end
	end
	local area = EEex_Area_GetVisible()
	if area ~= nil then GlideView_InRenderCorner = area.m_cInfinity.nNewX end
end

-- For test aids: the id this file follows, or nil
function GlideView_FollowId()
	return follow and follow.id
end

local hookAddress, problem = findHookAddress()
if hookAddress == nil then
	refuse(problem)
	return
end

EEex_DisableCodeProtection()

-- Shadow space 96 = 48 for six saved registers + 48 for a Lua call with one argument (rbx: the CInfinity drawn).
EEex_HookBeforeRestoreWithLabels(hookAddress, 0, HOOK_SIZE, HOOK_SIZE, {
	{"hook_integrity_watchdog_ignore_registers", {
		EEex_HookIntegrityWatchdogRegister.RAX,
	}}},
	EEex_FlattenTable({
		{[[
			#MAKE_SHADOW_SPACE(96)
			mov qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-8)], rcx
			mov qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-16)], rdx
			mov qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-24)], r8
			mov qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-32)], r9
			mov qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-40)], r10
			mov qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-48)], r11
		]]},
		EEex_GenLuaCall("GlideView_Hook_InRender", {
			["args"] = {
				function(rspOffset) return {"mov qword ptr ss:[rsp+#$(1)], rbx #ENDL", {rspOffset}} end,
			},
		}),
		{[[
			call_error:
			mov r11, qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-48)]
			mov r10, qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-40)]
			mov r9, qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-32)]
			mov r8, qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-24)]
			mov rdx, qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-16)]
			mov rcx, qword ptr ss:[rsp+#SHADOW_SPACE_BOTTOM(-8)]
			#DESTROY_SHADOW_SPACE
		]]},
	})
)

EEex_EnableCodeProtection()

-- The "View Damping" switch and the two damping settings, in the EEex Options menu under M_Glide.lua's tab "Glide", below its rows.
-- M_Glide.lua's "On/Off" switches this file too. EEex saves the values in the game's settings file,
-- section "Glide". Without EEex's options functions, or an M_Glide.lua without Glide_ExtraOptionEntries,
-- the values at the top stay.
local SETTINGS_SECTION = "Glide"
local TEXTS = {
	Glide_Enabled_Description = "Walking creatures glide between the game's movement steps, and the view glides when it follows a character: a held party number key, a double-click on a portrait, or a lock on a creature.",
	GlideView_ViewOn = "View Damping",
	GlideView_ViewOn_Description = "The view glides when it follows a character. Off: the view moves the game's own way. On/Off above turns this off too.",
	GlideView_FollowMs = "Follow Damping (ms)",
	GlideView_FollowMs_Description = "How long the view takes to catch up with the character it follows. 0 means instant.",
	GlideView_JumpMs = "Jump Damping (ms)",
	GlideView_JumpMs_Description = "How long the view takes to reach an off-screen character. 0 means instant.",
}

local function optionsAvailable()
	return EEex_Options_Register and EEex_Options_Option and EEex_Options_ClampedAccessor
		and EEex_Options_ToggleType and EEex_Options_ToggleWidget
		and EEex_Options_NumberLuaStorage and EEex_Options_DisplayEntry
		and EEex_Menu_AddTranslationLoadedListener and EEex_Options_EditType and EEex_Options_EditWidget
		and type(Glide_ExtraOptionEntries) == "table"
end

-- The game rebuilds its table of interface texts when it loads a language; add ours each time.
-- Registered after M_Glide.lua's, so the "On/Off" description above replaces Glide's own.
local function addTexts()
	if type(uiStrings) ~= "table" then return end
	for key, text in pairs(TEXTS) do uiStrings[key] = text end
end

local function saved(name)
	return EEex_Options_NumberLuaStorage.new({ ["section"] = SETTINGS_SECTION, ["key"] = name })
end

local function registerDamping(id, default, savedName, apply)
	local option = EEex_Options_Register(id, EEex_Options_Option.new({
		["default"]  = default,
		["type"]     = EEex_Options_EditType.new(),
		["accessor"] = EEex_Options_ClampedAccessor.new({ ["min"] = 0, ["max"] = MAX_DAMPING_MS }),
		["storage"]  = saved(savedName),
		["onChange"] = function(self) apply((self:get() or default) / MS_PER_SECOND) end,
	}))
	apply((option:get() or default) / MS_PER_SECOND)
end

local function dampingEntry(id)
	return function()
		return EEex_Options_DisplayEntry.new({
			["optionID"]    = id,
			["label"]       = id,
			["description"] = id .. "_Description",
			["widget"]      = EEex_Options_EditWidget.new({ ["maxCharacters"] = DAMPING_DIGITS, ["number"] = true }),
		})
	end
end

if optionsAvailable() then
	addTexts()
	EEex_Menu_AddTranslationLoadedListener(addTexts)
	local viewOption = EEex_Options_Register("GlideView_ViewOn", EEex_Options_Option.new({
		["default"]  = 1,
		["type"]     = EEex_Options_ToggleType.new(),
		["accessor"] = EEex_Options_ClampedAccessor.new({ ["min"] = 0, ["max"] = 1 }),
		["storage"]  = saved("View Damping"),
		["onChange"] = function(self) viewOn = (self:get() or 1) ~= 0 end,
	}))
	viewOn = (viewOption:get() or 1) ~= 0
	registerDamping("GlideView_FollowMs", FOLLOW_DAMPING_MS, "Follow Damping Ms", function(s) followSeconds = s end)
	registerDamping("GlideView_JumpMs", JUMP_DAMPING_MS, "Jump Damping Ms", function(s) jumpSeconds = s end)
	table.insert(Glide_ExtraOptionEntries, function()
		return EEex_Options_DisplayEntry.new({
			["optionID"]    = "GlideView_ViewOn",
			["label"]       = "GlideView_ViewOn",
			["description"] = "GlideView_ViewOn_Description",
			["widget"]      = EEex_Options_ToggleWidget.new(),
		})
	end)
	table.insert(Glide_ExtraOptionEntries, dampingEntry("GlideView_FollowMs"))
	table.insert(Glide_ExtraOptionEntries, dampingEntry("GlideView_JumpMs"))
else
	print("[GlideView] EEex options functions or Glide's tab not found: the damping stays as written at the top of the file")
end

-- For test aids: the current settings
function GlideView_Settings()
	return isOn(), followSeconds, jumpSeconds
end

GlideView_Installed = true
log("installed at " .. EEex_ToHex(hookAddress))
