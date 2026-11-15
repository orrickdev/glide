--[[
glide-refusal-test.lua - check offline that M_Glide.lua installs its hooks only when it should.

What it does: loads a hook file several times, each time with stand-in EEex functions (nothing from the
game or EEex runs) set up for one case, and checks what the file did:
  EEex absent                 no EEex functions at all: the file must load without an error and do nothing
  EEex function missing       EEex_Active set but one function absent: refusal (tried with two functions)
  EEex label missing          EEex_TryLabel finds no anchor for the body: refusal
  byte pattern not found      refusal
  byte pattern found twice    refusal
  second pattern mismatch     refusal
  circle label missing        EEex_TryLabel finds no anchor for the selection circle: refusal
  circle call not found       the call to the circle's drawing function is not where it is searched: refusal
  circle pattern mismatch     the bytes at the circle's hook point differ: refusal
  normal load                 exactly two hooks, at the expected addresses, calling Glide_Hook_OnRender
                              and Glide_Hook_OnMarker, and one memory block reserved
  backward call               the same with the circle's drawing function lying before its caller, the
                              call distance read as an unsigned and as a signed number
  second load                 loading the file again in the same game state installs nothing more
A refusal must raise exactly one error whose message starts with "[Glide] not installed: " (no file
and line prefix), and in every refusal case and in "EEex absent" no hook may be installed, no memory
written (EEex_Write32) or reserved (EEex_Malloc) and code protection never switched off.
Prints one line per case (PASS or FAIL and what was seen); exits with 1 when any case fails.

Run (Lua 5.2, e.g. the Ubuntu package lua5.2):
  lua5.2 glide-refusal-test.lua HOOK.lua
--]]

-- Simulated memory with the two byte patterns M_Glide.lua searches for the body (same layout as glide-replay.lua)
local ANCHOR = 0x1000
local ANCHOR_LABEL = "Hook-CGameSprite::Render()-B3Invis"
local BEFORE = {0x48,0x8B,0x46,0x0C,0x48,0x8D,0x56,0x0C,0x44,0x0F,0xB6,0x46,0x28,0x48,0x8B,0x4E,0x18,0x48,0x89,0x45,0x90}
local AFTER = {0x8B,0x55,0x94,0x4C,0x8B,0x4E,0x18,0x03,0xD0,0x89,0x55,0x94,0x41,0x8B,0x81,0x44,0x02,0x00,0x00}
local CALL_SIZE = 5
local BEFORE_AT = ANCHOR + 0x100
local AFTER_AT = BEFORE_AT + #BEFORE + CALL_SIZE
local SECOND_AFTER_AT = ANCHOR + 0x800      -- inside the searched range (0x1300 bytes after the anchor)
local HOOK_OFFSET = 12                      -- from the AFTER pattern to the hooked mov
local EXPECTED_HOOK = AFTER_AT + HOOK_OFFSET
local HOOK_FUNCTION = "Glide_Hook_OnRender"

-- Simulated memory for the selection circle: a call inside the function that holds the anchor, and
-- the hook point inside the called function.
local MARKER_ANCHOR = 0x5000
local MARKER_ANCHOR_LABEL = "Hook-CGameSprite::RenderMarkers()-B3Invis1"
local MARKER_CALL = {0x48,0x8D,0x8E,0xC8,0x4B,0x00,0x00,0x4C,0x8B,0xC6,0x49,0x8B,0xD6,0xE8}
local MARKER_HOOK = {
	0x4C,0x8B,0x47,0x18,0x4C,0x8D,0x4F,0x0C,0x89,0x4C,0x24,0x28,0x49,0x81,0xC0,
	0xC8,0x05,0x00,0x00,0x89,0x54,0x24,0x20,0x48,0x8B,0xCB,0x49,0x8B,0xD7,0xE8,
}
local MARKER_CALL_AT = MARKER_ANCHOR + 0x183
local CALL_DISTANCE_SIZE = 4
local MARKER_FUNCTION_AHEAD = 0x9000        -- start of the called function when it lies after its caller
local MARKER_FUNCTION_BEHIND = 0x3000       -- and when it lies before its caller
local MARKER_HOOK_OFFSET = 0xAA             -- from the start of the called function to the hook point
local RANGE_32 = 0x100000000
local MARKER_FUNCTION = "Glide_Hook_OnMarker"
local MARKER_POINT = 0x7000                 -- what the stand-in EEex_Malloc returns

local REFUSAL_PREFIX = "^%[Glide%] not installed: "

local function place(mem, at, bytes)
	for i, b in ipairs(bytes) do mem[at + i - 1] = b end
end

-- A fresh game state for one case. options: absent, noLabel, noPattern, twice, mismatch, missing (name),
-- noMarkerLabel, noMarkerCall, markerMismatch, backward ("unsigned" or "signed").
-- Returns the environment, what was seen, and the address the circle's hook is expected at.
local function newEnvironment(options)
	local seen = {hooks = {}, markerHooks = {}, writes = 0, unprotect = 0, allocations = 0, luaCalls = {}}
	if options.absent then return setmetatable({}, {__index = _G}), seen end
	local mem = {}
	if not options.noPattern then
		place(mem, BEFORE_AT, BEFORE)
		place(mem, AFTER_AT, AFTER)
	end
	if options.twice then place(mem, SECOND_AFTER_AT, AFTER) end
	if options.mismatch then mem[BEFORE_AT] = BEFORE[1] + 1 end

	local markerFunction = options.backward and MARKER_FUNCTION_BEHIND or MARKER_FUNCTION_AHEAD
	local expectedMarkerHook = markerFunction + MARKER_HOOK_OFFSET
	if not options.noMarkerCall then
		place(mem, MARKER_CALL_AT, MARKER_CALL)
		local distanceAt = MARKER_CALL_AT + #MARKER_CALL
		local distance = markerFunction - (distanceAt + CALL_DISTANCE_SIZE)
		if distance < 0 and options.backward == "unsigned" then distance = distance + RANGE_32 end
		mem[distanceAt] = distance            -- the stand-in EEex_Read32 returns the whole number from one cell
	end
	place(mem, expectedMarkerHook, MARKER_HOOK)
	if options.markerMismatch then mem[expectedMarkerHook] = MARKER_HOOK[1] + 1 end

	local labels = {
		[ANCHOR_LABEL] = not options.noLabel and ANCHOR or nil,
		[MARKER_ANCHOR_LABEL] = not options.noMarkerLabel and MARKER_ANCHOR or nil,
	}
	local env = {
		EEex_Active = true,
		EEex_TryLabel = function(label) return labels[label] end,
		EEex_ReadU8 = function(a) return mem[a] or 0 end,
		EEex_Read32 = function(a) return mem[a] or 0 end,
		EEex_Write32 = function(a, v) mem[a] = v; seen.writes = seen.writes + 1 end,
		EEex_Malloc = function() seen.allocations = seen.allocations + 1; return MARKER_POINT end,
		EEex_Utility_GetMicroseconds = function() return 0 end,
		EEex_DisableCodeProtection = function() seen.unprotect = seen.unprotect + 1 end,
		EEex_EnableCodeProtection = function() end,
		EEex_HookIntegrityWatchdogRegister = {},
		EEex_FlattenTable = function(t) return t end,
		EEex_GenLuaCall = function(name) seen.luaCalls[#seen.luaCalls + 1] = name; return {} end,
		EEex_HookBeforeRestoreWithLabels = function(address) seen.hooks[#seen.hooks + 1] = address end,
		EEex_HookAfterRestoreWithLabels = function(address) seen.markerHooks[#seen.markerHooks + 1] = address end,
	}
	if options.missing then env[options.missing] = nil end
	return setmetatable(env, {__index = _G}), seen, expectedMarkerHook
end

-- Runs the hook file once in env; returns true or false and the error message.
local function load(hookPath, env)
	local chunk = assert(loadfile(hookPath, "t", env))
	return pcall(chunk)
end

local function nothingDone(seen)
	return #seen.hooks == 0 and #seen.markerHooks == 0 and seen.writes == 0 and seen.unprotect == 0
		and seen.allocations == 0
end

local function describe(ok, message, seen)
	return string.format("loaded=%s hooks=%d circleHooks=%d writes=%d reserved=%d unprotect=%d message=%s",
		tostring(ok), #seen.hooks, #seen.markerHooks, seen.writes, seen.allocations, seen.unprotect,
		message and string.format("%q", message) or "none")
end

local REFUSALS = {
	{name = "EEex function missing", options = {missing = "EEex_HookBeforeRestoreWithLabels"}, reason = "EEex_HookBeforeRestoreWithLabels"},
	{name = "EEex function missing 2", options = {missing = "EEex_Malloc"}, reason = "EEex_Malloc"},
	{name = "EEex label missing", options = {noLabel = true}, reason = "label " .. ANCHOR_LABEL},
	{name = "byte pattern not found", options = {noPattern = true}, reason = "byte pattern not found"},
	{name = "byte pattern found twice", options = {twice = true}, reason = "byte pattern found twice"},
	{name = "second pattern mismatch", options = {mismatch = true}, reason = "second byte pattern does not match"},
	{name = "circle label missing", options = {noMarkerLabel = true}, reason = "label " .. MARKER_ANCHOR_LABEL},
	{name = "circle call not found", options = {noMarkerCall = true}, reason = "call that draws the selection circle not found"},
	{name = "circle pattern mismatch", options = {markerMismatch = true}, reason = "byte pattern of the selection circle does not match"},
}

-- Cases in which both hooks must be installed. options as for newEnvironment.
local LOADS = {
	{name = "normal load", options = {}},
	{name = "backward call, unsigned", options = {backward = "unsigned"}},
	{name = "backward call, signed", options = {backward = "signed"}},
}

-- shortcut: Lua has no argument parser in its standard library; the tool takes one positional argument.
local hookPath = arg[1]
assert(hookPath and #arg == 1, "usage: lua5.2 glide-refusal-test.lua HOOK.lua")

local failures = 0
local function report(name, pass, detail)
	if not pass then failures = failures + 1 end
	print(string.format("%-4s %-26s %s", pass and "PASS" or "FAIL", name, detail))
end

do
	local env, seen = newEnvironment({absent = true})
	local ok, message = load(hookPath, env)
	report("EEex absent", ok and nothingDone(seen) and not rawget(env, "Glide_Installed"), describe(ok, message, seen))
end

for _, case in ipairs(REFUSALS) do
	local env, seen = newEnvironment(case.options)
	local ok, message = load(hookPath, env)
	local clean = not ok and type(message) == "string" and message:find(REFUSAL_PREFIX) ~= nil
		and message:find(case.reason, 1, true) ~= nil
	report(case.name, clean and nothingDone(seen) and not rawget(env, "Glide_Installed"), describe(ok, message, seen))
end

for _, case in ipairs(LOADS) do
	local env, seen, expectedMarkerHook = newEnvironment(case.options)
	local ok, message = load(hookPath, env)
	local pass = ok and #seen.hooks == 1 and seen.hooks[1] == EXPECTED_HOOK
		and #seen.markerHooks == 1 and seen.markerHooks[1] == expectedMarkerHook
		and seen.writes == 0 and seen.allocations == 1
		and #seen.luaCalls == 2 and seen.luaCalls[1] == HOOK_FUNCTION and seen.luaCalls[2] == MARKER_FUNCTION
		and type(rawget(env, HOOK_FUNCTION)) == "function" and type(rawget(env, MARKER_FUNCTION)) == "function"
		and rawget(env, "Glide_Installed") == true
	report(case.name, pass, describe(ok, message, seen)
		.. string.format(" hookAddress=0x%X expected=0x%X circleHookAddress=0x%X expected=0x%X luaCalls=%s",
			seen.hooks[1] or 0, EXPECTED_HOOK, seen.markerHooks[1] or 0, expectedMarkerHook,
			table.concat(seen.luaCalls, ",")))

	local okAgain, messageAgain = load(hookPath, env)
	report(case.name .. ", again", okAgain and #seen.hooks == 1 and #seen.markerHooks == 1 and #seen.luaCalls == 2
		and seen.allocations == 1, describe(okAgain, messageAgain, seen))
end

print(string.format("%d failure(s)", failures))
os.exit(failures == 0 and 0 or 1)
