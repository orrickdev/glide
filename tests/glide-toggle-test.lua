--[[
glide-toggle-test.lua - check offline the on/off switch in M_Glide.lua.

What it does: loads a hook file with stand-in EEex functions, including a small stand-in for EEex's
options system (nothing from the game or EEex runs), and checks:
  registered        the four switches are registered, no key is registered, one tab with five entries is added
  circles switch    the switch "selection circles glide" off: the circle is at the real position while
                    the body still glides; on again: the circle glides
  texts             the menu texts are added to uiStrings, and again after the game rebuilds the table
  on by default     a walking creature's picture is shifted
  switch turns off  the switch "smooth movement" off: no shift
  circle when off   switched off, a walking creature's selection circle is at its real position
  switch turns on   the switch on again: the first draw starts afresh (no shift), the next step glides
  saves settings    every option uses EEex's file storage, section "Glide"; a changed switch is written
                    through it, and the mod writes nothing to the settings file by itself
  restored          a game start with saved settings: smooth movement off and the glide-in time as saved
  no key            the file names no key: no TOGGLE_KEY, no keybind, no on/off message
Prints one line per check (PASS or FAIL); exits with 1 when any check fails.

Run (Lua 5.2 or later):
  lua5.2 glide-toggle-test.lua HOOK.lua
--]]

-- Simulated memory with the two byte patterns M_Glide.lua searches for (same layout as glide-refusal-test.lua)
local ANCHOR = 0x1000
local BEFORE = {0x48,0x8B,0x46,0x0C,0x48,0x8D,0x56,0x0C,0x44,0x0F,0xB6,0x46,0x28,0x48,0x8B,0x4E,0x18,0x48,0x89,0x45,0x90}
local AFTER = {0x8B,0x55,0x94,0x4C,0x8B,0x4E,0x18,0x03,0xD0,0x89,0x55,0x94,0x41,0x8B,0x81,0x44,0x02,0x00,0x00}
local CALL_SIZE = 5
local BEFORE_AT = ANCHOR + 0x100
local AFTER_AT = BEFORE_AT + #BEFORE + CALL_SIZE
local FRAME_POINTER = 0x9000
-- The selection circle's byte patterns: a call close to the anchor, and the hook point in the called function
local MARKER_CALL = {0x48,0x8D,0x8E,0xC8,0x4B,0x00,0x00,0x4C,0x8B,0xC6,0x49,0x8B,0xD6,0xE8}
local MARKER_HOOK = {
	0x4C,0x8B,0x47,0x18,0x4C,0x8D,0x4F,0x0C,0x89,0x4C,0x24,0x28,0x49,0x81,0xC0,
	0xC8,0x05,0x00,0x00,0x89,0x54,0x24,0x20,0x48,0x8B,0xCB,0x49,0x8B,0xD7,0xE8,
}
local MARKER_CALL_AT = ANCHOR + 0x10
local CALL_DISTANCE_SIZE = 4
local MARKER_FUNCTION_AT = 0x4000
local MARKER_HOOK_OFFSET = 0xAA
local POINT = 0xA000              -- what the stand-in EEex_Malloc returns: the circle's position
local POINT_Y = 4
local OPTION_ENABLED = "Glide_Enabled"
local STEP_PX = 7                 -- one walking step
local STEP_US = 66667             -- two game ticks
local DRAW_US = 6944              -- one redraw at 144 per second
local LATER_US = 1000000          -- a second later: a new walk, well after any glide has ended
local KEY_WORDS = {"TOGGLE_KEY", "Keybind", "Infinity_DisplayString"}   -- none may be left in the mod

local function place(mem, at, bytes)
	for i, b in ipairs(bytes) do mem[at + i - 1] = b end
end

-- A stand-in for EEex's options system: just enough of it for M_Glide.lua.
local function newOptions(seen, stored)
	local Option = {}
	Option.__index = Option
	function Option:get() return self._value end
	function Option:_set(value, fromRead)
		local old = self._value
		self._value = value
		if not fromRead then self.storage:write(self, value) end
		if self.onChange and value ~= old then self:onChange(old) end
		return value
	end
	function Option:set(value)
		if value == nil then value = self.default end
		return self:_set(value, false)
	end
	local function plain(o) return o or {} end
	-- EEex's storages that write the settings file: counted, and every write counted
	local function fileStorage(o)
		seen.fileStorages = seen.fileStorages + 1
		seen.sections[tostring(o.section)] = true
		return {
			canReadEarly = function() return false end,
			read = function(_, option)
				local value = stored[o.key]
				if value == nil then return option.default end
				return value
			end,
			write = function(_, _, value)
				stored[o.key] = value
				seen.fileWrites = seen.fileWrites + 1
			end,
		}
	end
	return {
		EEex = {DeepCopy = function(v) return v end},
		Infinity_SetINIValue = function() seen.directWrites = seen.directWrites + 1 end,
		EEex_Options_Option = {new = function(o) return setmetatable(o, Option) end},
		-- as EEex once it has read its options: a new option is read at once
		EEex_Options_Register = function(id, option)
			seen.options[id] = option
			option:_set(option.storage:read(option), true)
			return option
		end,
		EEex_Options_Get = function(id) return seen.options[id] end,
		EEex_Options_AddTab = function(label, provider) seen.tabs[#seen.tabs + 1] = {label = label, entries = provider()} end,
		EEex_Options_ToggleType = {new = plain},
		EEex_Options_ClampedAccessor = {new = plain},
		EEex_Options_NumberLuaStorage = {new = fileStorage},
		EEex_Options_KeybindType = {new = plain},
		EEex_Options_KeybindAccessor = {new = plain},
		EEex_Options_KeybindLuaStorage = {new = fileStorage},
		EEex_Options_UnmarshalKeybind = function(text)
			seen.keyDefault = text
			return {text = text}
		end,
		EEex_Options_DisplayEntry = {new = plain},
		EEex_Options_ToggleWidget = {new = plain},
		EEex_Options_KeybindWidget = {new = plain},
		EEex_Options_EditType = {new = plain},
		EEex_Options_EditWidget = {new = plain},
		EEex_Menu_AddTranslationLoadedListener = function(listener) seen.translationListeners[#seen.translationListeners + 1] = listener end,
	}
end

-- A fresh game state with EEex and its options; stored: the settings file, saved values by name.
local function newEnvironment(stored)
	stored = stored or {}
	local seen = {writes = 0, messages = {}, options = {}, tabs = {}, translationListeners = {},
		fileStorages = 0, fileWrites = 0, directWrites = 0, sections = {}}
	local mem = {}
	place(mem, BEFORE_AT, BEFORE)
	place(mem, AFTER_AT, AFTER)
	for i, b in ipairs(MARKER_CALL) do mem[MARKER_CALL_AT + i - 1] = b end
	local distanceAt = MARKER_CALL_AT + #MARKER_CALL
	mem[distanceAt] = MARKER_FUNCTION_AT - (distanceAt + CALL_DISTANCE_SIZE)   -- the stand-in EEex_Read32 returns it whole
	for i, b in ipairs(MARKER_HOOK) do mem[MARKER_FUNCTION_AT + MARKER_HOOK_OFFSET + i - 1] = b end
	local clock = {now = 0}
	local screen = {active = "world", textFocus = 0}
	local env = {
		EEex_Active = true,
		EEex_TryLabel = function() return ANCHOR end,
		EEex_ReadU8 = function(a) return mem[a] or 0 end,
		EEex_Read32 = function(a) return mem[a] or 0 end,
		EEex_Write32 = function(a, v) mem[a] = v; seen.writes = seen.writes + 1 end,
		EEex_Utility_GetMicroseconds = function() return clock.now end,
		EEex_DisableCodeProtection = function() end,
		EEex_EnableCodeProtection = function() end,
		EEex_HookIntegrityWatchdogRegister = {},
		EEex_FlattenTable = function(t) return t end,
		EEex_GenLuaCall = function() return {} end,
		EEex_HookBeforeRestoreWithLabels = function() end,
		EEex_Malloc = function() return POINT end,
		EEex_HookAfterRestoreWithLabels = function() end,
		uiStrings = {},
		worldScreen = "world",
		e = {GetActiveEngine = function() return screen.active end},
		Infinity_TextEditHasFocus = function() return screen.textFocus end,
		Infinity_DisplayString = function(text) seen.messages[#seen.messages + 1] = text end,
		EngineGlobals = {g_pBaldurChitin = {m_pEngineWorld = {m_bPaused = 0}}},
	}
	for name, value in pairs(newOptions(seen, stored)) do env[name] = value end
	return setmetatable(env, {__index = _G}), seen, clock, screen, mem
end

-- One draw of a creature at x (y stays 0); returns how many memory writes it caused.
local function draw(env, seen, clock, sprite, x, at)
	clock.now = at
	sprite.m_pos.x = x
	local before = seen.writes
	env.Glide_Hook_OnRender(sprite, FRAME_POINTER)
	return seen.writes - before
end

-- Walks a creature one step and draws it once just after; returns the writes of that draw.
local function walkOneStep(env, seen, clock, sprite, from, at)
	draw(env, seen, clock, sprite, from, at)
	return draw(env, seen, clock, sprite, from + STEP_PX, at + STEP_US + DRAW_US)
end

-- The other switches, their values when the game starts, and the number of entries in the tab
local OPTION_CIRCLES = "Glide_Circles"
local OTHER_SWITCHES = {OPTION_CIRCLES, "Glide_CircleEase", "Glide_BodyEase"}
local SWITCHES_AT_START = "Glide_Circles=1 Glide_CircleEase=1 Glide_BodyEase=0"
local ENTRIES = 5
local OPTION_GLIDE_IN = "Glide_GlideInMs"
local GLIDE_IN_AT_START = 60              -- GLIDE_IN_MS at the top of M_Glide.lua
local GLIDE_IN_SET = 2000                 -- typed into the field during the test
local US_PER_MS = 1000
local SETTINGS_SECTION = "Glide"          -- the section of the settings file the mod's options are saved in
local SAVED_ENABLED = "Smooth Movement"   -- names the options are saved under
local SAVED_GLIDE_IN = "Glide-In Time Ms"

-- shortcut: Lua has no argument parser in its standard library; the tool takes one positional argument.
local hookPath = arg[1]
assert(hookPath and #arg == 1, "usage: lua5.2 glide-toggle-test.lua HOOK.lua")

local failures = 0
local function report(name, pass, detail)
	if not pass then failures = failures + 1 end
	print(string.format("%-4s %-16s %s", pass and "PASS" or "FAIL", name, detail))
end

do
	local env, seen, clock, screen, mem = newEnvironment({})
	assert(loadfile(hookPath, "t", env))()

	local tab = seen.tabs[1]
	local switchesAtStart = {}
	for _, id in ipairs(OTHER_SWITCHES) do
		local option = seen.options[id]
		switchesAtStart[#switchesAtStart + 1] = id .. "=" .. tostring(option and option:get())
	end
	local switchesText = table.concat(switchesAtStart, " ")
	local options = 0
	for _ in pairs(seen.options) do options = options + 1 end
	report("registered", seen.options[OPTION_ENABLED] ~= nil and seen.keyDefault == nil
		and options == ENTRIES and #seen.tabs == 1 and #tab.entries[1] == ENTRIES
		and switchesText == SWITCHES_AT_START,
		string.format("key %s, options %d, tabs %d, entries %d, %s", tostring(seen.keyDefault), options,
			#seen.tabs, #tab.entries[1], switchesText))

	local textsNow = env.uiStrings[tab.label] ~= nil
	env.uiStrings = {}                                   -- the game rebuilds the table on a language load
	for _, listener in ipairs(seen.translationListeners) do listener() end
	local textsAgain = env.uiStrings[tab.label]
	report("texts", textsNow and textsAgain == "Glide", string.format("tab title %q", tostring(textsAgain)))

	local sprite = {m_id = 1, m_pos = {x = 0, y = 0}}
	local onWrites = walkOneStep(env, seen, clock, sprite, 0, 0)
	report("on by default", onWrites > 0, string.format("writes on the draw after a step: %d", onWrites))

	seen.options[OPTION_ENABLED]:set(0)
	local offWrites = walkOneStep(env, seen, clock, sprite, STEP_PX, LATER_US)
	report("switch turns off", offWrites == 0, string.format("writes %d", offWrites))

	if env.Glide_Hook_OnMarker then                     -- hook files from before the circle glided have no such routine
		clock.now = LATER_US + STEP_US + 2 * DRAW_US
		env.Glide_Hook_OnMarker(sprite, POINT)
		report("circle when off", mem[POINT] == sprite.m_pos.x and mem[POINT + POINT_Y] == sprite.m_pos.y,
			string.format("circle at %s,%s, creature at %d,%d", tostring(mem[POINT]), tostring(mem[POINT + POINT_Y]),
				sprite.m_pos.x, sprite.m_pos.y))
	end

	seen.options[OPTION_ENABLED]:set(1)
	local resumeAt = 2 * LATER_US
	local firstWrites = draw(env, seen, clock, sprite, 3 * STEP_PX, resumeAt)
	local stepWrites = draw(env, seen, clock, sprite, 4 * STEP_PX, resumeAt + STEP_US + DRAW_US)
	report("switch turns on", firstWrites == 0 and stepWrites > 0,
		string.format("first draw writes %d, next step writes %d", firstWrites, stepWrites))

	do
		local walker = {m_id = 3, m_pos = {x = 0, y = 0}}
		local start = 4 * LATER_US
		seen.options[OPTION_CIRCLES]:set(0)
		local bodyWrites = walkOneStep(env, seen, clock, walker, 0, start)
		env.Glide_Hook_OnMarker(walker, POINT)
		local circleOff = mem[POINT] - walker.m_pos.x
		seen.options[OPTION_CIRCLES]:set(1)
		clock.now = clock.now + DRAW_US
		env.Glide_Hook_OnMarker(walker, POINT)
		local circleOn = mem[POINT] - walker.m_pos.x
		report("circles switch", bodyWrites > 0 and circleOff == 0 and circleOn < 0,
			string.format("switch off: body writes %d, circle %d from the real position; on again: circle %d", bodyWrites, circleOff, circleOn))
	end

	do
		local glideIn = seen.options[OPTION_GLIDE_IN]
		local atStart = glideIn and glideIn:get()
		local walker = {m_id = 4, m_pos = {x = 0, y = 0}}
		local start = 6 * LATER_US
		if glideIn then glideIn:set(GLIDE_IN_SET) end
		walkOneStep(env, seen, clock, walker, 0, start)
		local pauseAt = clock.now + DRAW_US
		env.EngineGlobals.g_pBaldurChitin.m_pEngineWorld.m_bPaused = 1
		clock.now = pauseAt
		env.Glide_Hook_OnMarker(walker, POINT)
		local atPause = mem[POINT] - walker.m_pos.x
		-- the game keeps redrawing while paused: one circle and one body per redraw
		local function redrawUntil(untilUs)
			while clock.now < untilUs do
				clock.now = clock.now + DRAW_US
				env.Glide_Hook_OnMarker(walker, POINT)
				env.Glide_Hook_OnRender(walker, FRAME_POINTER)
			end
			return mem[POINT] - walker.m_pos.x
		end
		local halfway = redrawUntil(pauseAt + GLIDE_IN_SET * US_PER_MS / 2)
		local done = redrawUntil(pauseAt + GLIDE_IN_SET * US_PER_MS + DRAW_US)
		env.EngineGlobals.g_pBaldurChitin.m_pEngineWorld.m_bPaused = 0
		report("glide-in field", atStart == GLIDE_IN_AT_START and atPause < 0 and halfway < 0
			and halfway > atPause and done == 0,
			string.format("at start %s ms; set to %d ms: circle at the pause %d, after %d ms %d, after %d ms %d",
				tostring(atStart), GLIDE_IN_SET, atPause, GLIDE_IN_SET / 2, halfway, GLIDE_IN_SET, done))
	end

	local sections = {}
	for section in pairs(seen.sections) do sections[#sections + 1] = section end
	report("saves settings", seen.fileStorages == ENTRIES and #sections == 1 and sections[1] == SETTINGS_SECTION
		and seen.fileWrites > 0 and seen.directWrites == 0,
		string.format("EEex file storages used %d, section %s, writes through them %d, writes by the mod itself %d",
			seen.fileStorages, table.concat(sections, ","), seen.fileWrites, seen.directWrites))
	report("no message", #seen.messages == 0, string.format("messages shown %d", #seen.messages))
end

-- A game start with saved settings.
do
	local env, seen, clock = newEnvironment({[SAVED_ENABLED] = 0, [SAVED_GLIDE_IN] = GLIDE_IN_SET})
	assert(loadfile(hookPath, "t", env))()
	local sprite = {m_id = 1, m_pos = {x = 0, y = 0}}
	local writes = walkOneStep(env, seen, clock, sprite, 0, 0)
	local enabledNow, glideInNow = seen.options[OPTION_ENABLED]:get(), seen.options[OPTION_GLIDE_IN]:get()
	report("restored", writes == 0 and enabledNow == 0 and glideInNow == GLIDE_IN_SET,
		string.format("saved off and %d ms: smooth movement %s, writes on a step %d, glide-in time %s ms",
			GLIDE_IN_SET, tostring(enabledNow), writes, tostring(glideInNow)))
end

-- No key is left in the mod file.
do
	local file = assert(io.open(hookPath, "r"))
	local source = file:read("*a")
	file:close()
	local found = {}
	for _, word in ipairs(KEY_WORDS) do
		if source:find(word, 1, true) then found[#found + 1] = word end
	end
	report("no key", #found == 0, "found: " .. (#found == 0 and "none" or table.concat(found, ", ")))
end

print(string.format("%d failure(s)", failures))
os.exit(failures == 0 and 0 or 1)
