--[[
    AutoFish - full auto fishing bot for Fisch  (placeId 131716211654599)
    ======================================================================
    What it does:
      * Cast     - casts the rod by itself through RF/FishingRod/Cast,
                   so it keeps working while the window is minimized
      * Shake    - clicks the LureShake mini-game circles for you
      * Reel     - steers the slider onto the fish, frame by frame
      * Perfect  - "Auto Lock" mode snaps the bar onto the fish, so every
                   catch is rated Perfect (never Amazing / Great)
      * Farm     - auto sell to the angler + auto equip bait
      * Style    - neon interface with sounds, glow and a custom font

    Access key: the script starts locked. As soon as the file is executed the
    Discord invite is copied into the clipboard, so handing the key out is a
    single paste. Paste the key into the first section of the window to unlock
    the bot. The key is asked again on every run and is never written to disk.

    How to run:  paste the whole file into your executor (Madium / Fluxus / ...)
    How to stop: toggle in the window, press F5, or call
                 _G.__AutoFish.Disable()  /  _G.__AutoFish.Stop()

    Sharing:    AutoFish.min.lua is the compressed build of this file. Rebuild it
                after every change:
                    powershell -ExecutionPolicy Bypass -File build.ps1
                WINDUI_URLS below is what makes the compressed build work on a
                machine that has no windui.lua on disk: host the library once and
                drop the link in there.

    The window may stay minimized: everything runs over the network and over
    the game's own signals, no real mouse needed.
--]]

--------------------------------------------------------------------------------
--  SERVICES
--------------------------------------------------------------------------------

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local SoundService      = game:GetService("SoundService")
local ContentProvider   = game:GetService("ContentProvider")

local LocalPlayer = Players.LocalPlayer

-- where the script keeps its files; declared up here because the island spots
-- and the settings both live in this folder
local CFG_FOLDER = "AutoFish"
local CFG_FILE   = "autofish.cfg.json"

--------------------------------------------------------------------------------
--  ACCESS KEY
--------------------------------------------------------------------------------
--  The bot boots locked: the Discord invite lands in the clipboard the moment
--  the file is executed, so passing the key on is a single paste. Paste the key
--  into the first section of the window and the menu unlocks.
--  Re-brand or re-key the script from these two lines only.
--------------------------------------------------------------------------------

local DISCORD_LINK = "https://discord.gg/BRvMZV4qwz"
local ACCESS_KEY   = "X3gkDN"

--------------------------------------------------------------------------------
--  SETTINGS  (the defaults are already tuned - nothing has to be changed)
--------------------------------------------------------------------------------

local Config = {
	Enabled   = false,   -- master switch
	Theme     = "Dark",

	-- subsystems
	Cast      = true,    -- auto cast + auto hook
	Shake     = true,    -- auto shake (mini-game circles)
	Reel      = true,    -- auto reel
	Farm      = false,   -- auto sell / auto bait

	-- reel
	ReelAuto  = true,    -- auto lock: bar sticks to the fish -> PERFECT
	ReelHorizon = 0.35,  -- prediction horizon, seconds
	ReelFlip  = 0.10,    -- penalty for flipping direction (bar width fraction)
	ReelMouse = false,   -- true = drive with the real mouse instead of rod:Input*

	-- shake
	ShakeGap  = 0.10,    -- minimum delay between clicks, seconds
	ShakeGui  = false,   -- true = click circles with the real mouse

	-- cast
	CastPause = 1.60,    -- delay between casts, seconds
	CastRetry = 1.50,    -- delay after a rejected cast, seconds
	CastTries = 5,       -- attempts in a row before a rest
	CastPower = 1.0,     -- cast power, 0..1
	Hook      = false,   -- click during "Searching" (normally not needed)
	HookGap   = 0.35,    -- delay between hook clicks, seconds
	AutoEquip = true,    -- pull the rod out of the backpack

	-- farm
	SellEvery = 45,      -- auto sell every N seconds (0 = off)
	Bait      = "Keep current",
	AutoBait  = true,

	-- travel
	TpFloat   = true,    -- hold the character on the surface in open water (no drowning)

	-- look & feel
	Accent    = "Cyan",  -- neon accent colour (see ACCENTS)
	Font      = "GothamBlack",
	Glow      = true,    -- neon text glow
	GlowLevel = 0.70,    -- glow strength, 0..1
	Anim      = true,    -- press animation
	Sound     = true,    -- interface sounds
	Volume    = 0.35,    -- interface sound volume, 0..1

	Debug     = false,   -- verbose console log
}

local RodStateNames = {
	[0] = "Destroyed", [1] = "Unequipped", [2] = "Equipping",
	[3] = "Equipped",  [4] = "Casting",   [5] = "Searching",
	[6] = "Shaking",   [7] = "Hooking",   [8] = "Reeling", [9] = "Caught",
}

local ST_DESTROYED, ST_UNEQUIPPED, ST_EQUIPPING, ST_EQUIPPED = 0, 1, 2, 3
local ST_CASTING, ST_SEARCHING, ST_LURING, ST_PREREEL = 4, 5, 6, 7
local ST_REELING, ST_FINISHED = 8, 9

--------------------------------------------------------------------------------
--  RUNTIME STATE
--------------------------------------------------------------------------------

local S = {
	conns      = {},

	-- reel
	reelDir    = 0,
	reelFlipAt = 0,
	reelMouse  = false,
	reelProg   = 0,      -- 0..100 (the game counts in percent)
	reelOnBar  = false,
	reelPerfect = true,
	reelSeen   = 0,
	reelAssist = false,  -- auto lock is really installed on this reel
	assistList = {},     -- reel -> minigame, so we can unwrap later

	-- shake
	dial       = nil,
	dialMiss   = 0,
	shakeAt    = 0,

	-- cast
	castAt     = 0,
	tryAt      = 0,
	tryState   = -1,
	tries      = 0,
	hookAt     = 0,
	equipAt    = 0,

	-- farm
	sellAt     = 0,
	baitAt     = 0,
	baits      = { "Keep current" },
	anglers    = {},
	anglerAt   = 0,
	caught0    = nil,

	fishName   = "",
	status     = "Locked",
	note       = "",
	notify     = nil,
	home       = nil,   -- where the character stood when the script booted
	floatTop   = 0,     -- surface height of the last water destination, 0 = off

	-- access key
	unlocked   = false,
	badKey     = 0,
	lockList   = {},   -- every widget the menu built
	keyFrames  = {},   -- frames of the key gate   (shown while locked)
	hintFrames = {},   -- frames of the lock notes (shown while locked)
}

--------------------------------------------------------------------------------
--  UTILITIES
--------------------------------------------------------------------------------

local function now() return os.clock() end

local function keep(conn)
	table.insert(S.conns, conn)
	return conn
end

local function dropAll()
	for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
	table.clear(S.conns)
end

local function logf(fmt, ...)
	if not Config.Debug then return end
	local ok, msg = pcall(string.format, fmt, ...)
	print("[AutoFish] " .. (ok and msg or tostring(fmt)))
end

local function notify(title, text, kind)
	if not S.notify then return end
	pcall(S.notify, {
		Title    = title,
		Text     = text,
		Duration = 3,
		Sound    = (kind == "Error") and "Error" or (kind == "Success" and "Success" or nil),
	})
end

local function setStatus(text, note)
	S.status = text
	if note ~= nil then S.note = note end
end

local function stateName(s)
	return RodStateNames[s] or ("?" .. tostring(s))
end

local function windowFocused()
	if type(iswindowactive) == "function" then
		return iswindowactive()
	end
	return true
end

--------------------------------------------------------------------------------
--  GAME MODULES
--------------------------------------------------------------------------------

local Controllers = ReplicatedStorage:WaitForChild("client"):WaitForChild("legacyControllers")

local ReelController   = require(Controllers:WaitForChild("ReelController"))
local FishingRodCtl   = require(Controllers:WaitForChild("FishingRodController"))
local DataController   = require(Controllers:WaitForChild("DataController"))

--------------------------------------------------------------------------------
--  THE ROD
--------------------------------------------------------------------------------

local function getTool()
	local ch = LocalPlayer.Character
	return ch and ch:FindFirstChildWhichIsA("Tool") or nil
end

--- Tool with a handle, so it is a rod and not something else
local function rodTool()
	local tool = getTool()
	if not tool then return nil end
	if tool:FindFirstChild("handle") then return tool end
	return nil
end

--- Rod state number (nil when unknown)
local function rodState()
	local tool = getTool()
	if not tool then return nil, nil end

	local values = tool:FindFirstChild("values")
	local st = values and values:FindFirstChild("state")
	if st and st:IsA("IntValue") then
		return st.Value, tool
	end

	local rod = FishingRodCtl.GetRod and FishingRodCtl.GetRod()
	if rod and type(rod.State) == "number" then
		return rod.State, tool
	end

	return nil, tool
end

local function equipRod()
	local ch = LocalPlayer.Character
	if not ch then return false end
	if rodTool() then return true end

	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		or (ch:FindFirstChildOfClass("Backpack"))
	if not backpack then return false end

	local hum = ch:FindFirstChildOfClass("Humanoid")
	if not hum then return false end

	local preferred = LocalPlayer:GetAttribute("CurrentRod")
	local first, rest = nil, {}

	for _, item in ipairs(backpack:GetChildren()) do
		if item:IsA("Tool") and item:FindFirstChild("handle") then
			if preferred and item.Name == preferred then
				first = first or item
			else
				table.insert(rest, item)
			end
		end
	end

	if first then
		hum:EquipTool(first)
		return true
	end
	if rest[1] then
		hum:EquipTool(rest[1])
		return true
	end
	return false
end

--------------------------------------------------------------------------------
--  REEL ENGINE
--------------------------------------------------------------------------------
--  Bar physics (ReelController.Core.RodMovement.Tick):
--      v_target = direction * barMoveSpeed * clamp(accel, -1, 1) * 1.5
--                 (the target speed is zeroed at the track ends)
--      velocity, acceleration = SmoothDamp(velocity, v_target, acceleration,
--                                          clamp(0.85 / sqrt(|accel|)), inf, dt)
--      barPosition += velocity * dt, with a 0.5 elastic bounce off the ends
--
--  The fish (Core.FishMovement.Tick) uses the very same formula, only its
--  target is CurrentTarget and its smoothing is CurrentMoveTime. Both
--  trajectories can therefore be predicted frame by frame instead of guessed.
--
--  Control: every frame we simulate TWO candidates - "keep the direction" and
--  "flip right now" - through the exact SmoothDamp over the ReelHorizon and
--  take the one with the smaller deviation. No dead zone, no lead, so the bar
--  never oscillates and it brakes exactly when it would have overshot.
--
--  Auto lock (ReelAuto): wraps Core.Minigame.Tick so the bar is placed right on
--  the fish just before the "is the fish inside the bar?" check. The game only
--  sets perfect = false while the fish is outside, so the rating is always
--  Perfect. Mouse control is not needed while it is on.
--------------------------------------------------------------------------------

local SIM_DT = 1 / 120   -- prediction step

--- Exact copy of TweenService:SmoothDamp (maxSpeed = inf, like in the game)
local function smoothStep(cur, target, curVel, smoothTime, dt)
	smoothTime = math.clamp(smoothTime, 0.0001, 1e6)
	local omega = 2 / smoothTime
	local x = omega * dt
	local ex = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
	local change = cur - target
	local originalTo = target
	target = cur - change
	local temp = (curVel + omega * change) * dt
	curVel = (curVel - omega * temp) * ex
	local out = target + (change + temp) * ex
	if (originalTo - cur > 0) == (out > originalTo) then
		out = originalTo
		curVel = (out - originalTo) / dt
	end
	return out, curVel
end

--- Runs "direction dir" for steps frames ahead and returns
--- (max deviation of the bar from the fish, final deviation).
--- The first frame is skipped: both candidates deviate equally there.
local function simulate(reel, dir, vel0, accel0, steps, fpos, fvel, ftarget, ftime)
	local accel = math.clamp(tonumber(reel.accel) or 1, -1, 1)
	local vMax  = (tonumber(reel.barMoveSpeed) or 1) * accel * 1.5
	local tau   = 0.85 / math.sqrt(math.max(math.abs(accel), 1e-6))

	local size  = tonumber(reel.barSize) or 0.1
	local lo    = (tonumber(reel.minBarPosition) or 0) + size * 0.5
	local hi    = (tonumber(reel.maxBarPosition) or 1) - size * 0.5
	if hi < lo then lo, hi = 0.5, 0.5 end

	local x  = tonumber(reel.barPosition) or 0.5
	local v  = vel0
	local aS = accel0
	local fp, fv = fpos, fvel
	local maxDev = 0

	for i = 1, steps do
		if i > 1 then
			local dev = math.abs(x - fp)
			if dev > maxDev then maxDev = dev end
		end

		local vT = dir * vMax
		if (x <= lo and vT < 0) or (x >= hi and vT > 0) then vT = 0 end

		v, aS = smoothStep(v, vT, aS, tau, SIM_DT)
		x = x + v * SIM_DT
		if x < lo then
			x, v = lo, -v * 0.5
		elseif x > hi then
			x, v = hi, -v * 0.5
		end

		fp, fv = smoothStep(fp, ftarget, fv, ftime, SIM_DT)
		if fp < 0 then
			fp = 0; if fv < 0 then fv = 0 end
		elseif fp > 1 then
			fp = 1; if fv > 0 then fv = 0 end
		end
	end

	return maxDev, math.abs(x - fp)
end

--- Snaps the bar onto the fish right before the progress check.
--- PATCH keeps the wrapper state inside the script (not on the game module),
--- so restarting the script never leaves dead wrappers behind.
local PATCH = {}

local function assistInstall(reel)
	if not reel then return false end
	local core = reel.core
	local mg = core and core.minigame
	if type(mg) ~= "table" or type(mg.Tick) ~= "function" then return false end

	-- already wrapped (fresh, or left over from a previous load - same logic)
	if mg.__afToken == PATCH.token then
		reel.__afAssist = true
		return true
	end

	local orig = mg.Tick
	mg.__afOrig = orig
	mg.Tick = function(self, dt)
		local c = self.current
		if Config.ReelAuto and c and c.active and not self.Disabled then
			local size = tonumber(c.barSize) or 0
			if size >= 1 then
				c.barPosition = 0.5
			elseif size > 0 then
				local lo = (tonumber(c.minBarPosition) or 0) + size * 0.5
				local hi = (tonumber(c.maxBarPosition) or 1) - size * 0.5
				if hi > lo then
					c.barPosition = math.clamp(tonumber(c.fishPosition) or 0.5, lo, hi)
				end
			end
		end
		return orig(self, dt)
	end

	mg.__afToken = PATCH.token
	reel.__afAssist = true
	S.assistList[reel] = mg
	return true
end

local function assistRemove()
	for reel, mg in pairs(S.assistList) do
		if type(mg.Tick) == "function" and mg.__afOrig then
			mg.Tick = mg.__afOrig
		end
		mg.__afOrig = nil
		mg.__afToken = nil
		reel.__afAssist = nil
	end
	table.clear(S.assistList)

	-- drop the StartReel wrapper too, if it is ours
	if PATCH.wrapper and PATCH.startReelOrig
		and ReelController.StartReel == PATCH.wrapper then
		ReelController.StartReel = PATCH.startReelOrig
	end
	PATCH.wrapper = nil
	PATCH.startReelOrig = nil
end

--- Installs auto lock the moment a reel is created
local function assistHook()
	-- our own unique key: a foreign (previous) wrapper is always replaced
	PATCH.token = {}
	PATCH.wrapper = function(...)
		local reel = PATCH.startReelOrig(...)
		pcall(assistInstall, reel)
		return reel
	end
	PATCH.startReelOrig = ReelController.StartReel
	ReelController.StartReel = PATCH.wrapper
end

local function reelRelease()
	if S.reelMouse then
		S.reelMouse = false
		pcall(mouse1release)
	end
	if S.reelDir ~= 0 then
		pcall(function()
			local reel = ReelController.ActiveReel
			local rod = reel and reel.core and reel.core.rod
			if rod then rod:InputEnded() end
		end)
	end
	S.reelDir = 0
end

local function reelApply(dir)
	local reel = ReelController.ActiveReel
	if not reel then return end
	local rod = reel.core and reel.core.rod
	if not rod then return end

	-- some passives block input for a moment
	if type(rod.InputLockedUntil) == "number"
		and rod.InputLockedUntil > workspace:GetServerTimeNow() then
		return
	end
	if rod.Disabled then return end

	if Config.ReelMouse then
		if dir > 0 and not S.reelMouse then
			S.reelMouse = true
			pcall(mouse1press)
		elseif dir < 0 and S.reelMouse then
			S.reelMouse = false
			pcall(mouse1release)
		end
		S.reelDir = dir
		return
	end

	if dir > 0 then
		pcall(rod.InputBegan, rod)
	else
		pcall(rod.InputEnded, rod)
	end
	S.reelDir = dir
end

local function reelStep()
	local reel = ReelController.ActiveReel
	if not reel then
		if S.reelSeen > 0 then
			logf("reel closed")
			S.reelSeen = 0
		end
		S.reelAssist = false
		return reelRelease()
	end

	local core = reel.core
	local rod  = core and core.rod
	local fish = core and core.fish
	if not rod or not fish then
		return reelRelease()
	end

	-- auto lock: install / keep the wrapper
	if Config.ReelAuto and not reel.__afAssist then
		pcall(assistInstall, reel)
	end
	S.reelAssist = (reel.__afAssist == true) and Config.ReelAuto or false

	S.reelSeen    = S.reelSeen + 1
	S.reelProg    = tonumber(reel.progress) or 0
	S.reelOnBar   = reel.onbar and true or false
	S.reelPerfect = reel.perfect ~= false
	S.fishName    = (reel.fish and reel.fish.Name) or S.fishName

	if not reel.active then return end

	-- with auto lock the game drives the bar, we do not touch the mouse
	if S.reelAssist then return end

	local size = tonumber(reel.barSize) or 0.1
	if size >= 1 then
		reel.barPosition = 0.5
		S.reelDir = 0
		return
	end

	--------------------------------------------------------------------------
	--  control state
	--------------------------------------------------------------------------
	local cur = rod.CurrentInputDirection
	if cur ~= 1 and cur ~= -1 then cur = -1 end
	if S.reelDir == 0 then S.reelDir = cur end
	if S.reelDir ~= cur then
		-- direction got reset (passive, bounce) - pick it up again
		S.reelDir = cur
	end

	local aS = tonumber(rod.CurrentAcceleration) or 0
	local vel = tonumber(rod.CurrentVelocity) or 0

	--------------------------------------------------------------------------
	--  fish prediction over the same horizon
	--------------------------------------------------------------------------
	local fpos  = tonumber(reel.fishPosition) or 0.5
	local fvel  = tonumber(fish.CurrentVelocity) or 0
	local ftgt  = tonumber(fish.CurrentTarget)
	if not ftgt then ftgt = fpos end
	local ftime = tonumber(fish.CurrentMoveTime) or 0.3
	if fish.MovementPaused or fish.Disabled
		or (tonumber(reel.frozenUntil) or 0) > os.clock() then
		-- the fish is standing still - just hold the bar on it
		ftgt, fvel = fpos, 0
	end

	local steps = math.clamp(math.floor((Config.ReelHorizon or 0.3) / SIM_DT), 4, 120)

	--------------------------------------------------------------------------
	--  choice: flip only when it is clearly better.
	--  maxDev keeps the fish inside the bar, endDev keeps the bar off the
	--  wall once the deviation is already big and both options tie.
	--------------------------------------------------------------------------
	local dKeep, eKeep = simulate(reel,  S.reelDir, vel, aS, steps, fpos, fvel, ftgt, ftime)
	local dFlip, eFlip = simulate(reel, -S.reelDir, vel, 0,   steps, fpos, fvel, ftgt, ftime)

	local penalty = size * (Config.ReelFlip or 0.1)
	local scoreKeep = dKeep + 0.6 * eKeep
	local scoreFlip = dFlip + 0.6 * eFlip + penalty
	local want = (scoreFlip < scoreKeep) and -S.reelDir or S.reelDir

	if want ~= S.reelDir then
		local speed = math.abs(vel)
		local minGap = math.clamp(speed * 0.02, 0, 0.05)
		if (now() - S.reelFlipAt) >= minGap then
			S.reelFlipAt = now()
			reelApply(want)
			logf("reel: flip %.4f/%.4f -> %.4f/%.4f (fish %.3f, bar %.3f)",
				dKeep, eKeep, dFlip, eFlip, fpos, tonumber(reel.barPosition) or 0)
		end
	end
end

--------------------------------------------------------------------------------
--  SHAKE ENGINE
--------------------------------------------------------------------------------
--  A circle is a clone of the template from resources/replicated/fishing/
--  customshakes that the game parents to PlayerGui -> shakeui -> safezone.
--  The game listens to btn.Activated, so firing those handlers is enough.
--------------------------------------------------------------------------------

local function findDial()
	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not pg then return nil end

	local ui = pg:FindFirstChild("shakeui")
	local root = ui and ui:FindFirstChild("safezone") or ui
	if not root then return nil end

	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("GuiButton") and d:FindFirstChild("consoleStroke") then
			return d
		end
	end
	return nil
end

local function fireActivated(gui)
	local fired = false
	if type(getconnections) == "function" and type(getconnectionfunction) == "function" then
		for _, conn in ipairs(getconnections(gui.Activated)) do
			local skip = false
			if type(isconnectionenabled) == "function" and not isconnectionenabled(conn) then
				skip = true
			end
			local fn = skip and nil or getconnectionfunction(conn)
			if type(fn) == "function" then
				pcall(fn)
				fired = true
			end
		end
	end
	if not fired and type(firesignal) == "function" then
		pcall(function() gui:FireSignal("Activated") end)
		fired = true
	end
	return fired
end

local function shakeStep()
	local state = rodState()
	if state ~= ST_LURING then
		if S.dial then S.dial = nil end
		return
	end

	local t = now()
	if t - S.shakeAt < Config.ShakeGap then return end

	local btn = S.dial
	if not btn or not btn.Parent then
		btn = findDial()
		S.dial = btn
	end
	if not btn then
		S.dialMiss = S.dialMiss + 1
		return
	end

	S.shakeAt = t

	if Config.ShakeGui then
		local c = btn.AbsolutePosition + btn.AbsoluteSize * 0.5
		pcall(mouse1move, c.X, c.Y)
		pcall(mouse1click)
	else
		fireActivated(btn)
	end

	if btn and btn.Parent then
		local alive = findDial()
		S.dial = (alive ~= btn) and alive or nil
	end
end

--------------------------------------------------------------------------------
--  CAST ENGINE
--------------------------------------------------------------------------------
--  A normal cast is handled by LMB on the client side, and Windows drops
--  synthetic input when the window is not focused. So we always send the exact
--  request the game itself sends on a click:
--      ReplicatedStorage.packages.Net["RF/FishingRod/Cast"]:InvokeServer(power, false)
--  It is a plain RemoteFunction, so it works minimized and unfocused, and there
--  is no mouse mode at all.
--------------------------------------------------------------------------------

local function castRemote()
	local pkgs = ReplicatedStorage:FindFirstChild("packages")
	local net  = pkgs and pkgs:FindFirstChild("Net")
	local rf   = net and net:FindFirstChild("RF/FishingRod/Cast")
	if not rf then return false, "RF/FishingRod/Cast not found" end

	local power = math.clamp(tonumber(Config.CastPower) or 1, 0, 1)
	local ok, res = pcall(function() return rf:InvokeServer(power, false) end)
	if not ok then return false, tostring(res) end
	return res == true, (res == true) and "" or "server rejected it"
end

local function castStep()
	local state, tool = rodState()

	--------------------------------------------------------------------------
	--  no rod in hand
	--------------------------------------------------------------------------
	if not tool then
		setStatus("No rod", "Pulling it out of the backpack...")
		if Config.AutoEquip and (now() - S.equipAt) > 1.5 then
			S.equipAt = now()
			equipRod()
		end
		return
	end

	--------------------------------------------------------------------------
	--  wait until the rod is ready
	--------------------------------------------------------------------------
	if state == ST_SEARCHING or state == ST_LURING
		or state == ST_PREREEL or state == ST_REELING then
		S.tries = 0
		return
	end

	if state ~= ST_EQUIPPED and state ~= ST_FINISHED and state ~= ST_UNEQUIPPED then
		if state == ST_DESTROYED or state == ST_EQUIPPING then
			if Config.AutoEquip and (now() - S.equipAt) > 1.5 then
				S.equipAt = now()
				equipRod()
			end
		end
		return
	end

	--------------------------------------------------------------------------
	--  delay between casts / after a rejected one
	--------------------------------------------------------------------------
	if (now() - S.castAt) < (S.tries > 0 and Config.CastRetry or Config.CastPause) then
		return
	end

	--------------------------------------------------------------------------
	--  cast
	--------------------------------------------------------------------------
	local ok, why = castRemote()
	S.tryAt = now()

	if ok then
		S.tries = 0
		S.castAt = now()
		setStatus(stateName(state), "Cast sent")
		logf("cast request sent (state=%s)", tostring(state))
	else
		S.tries = S.tries + 1
		S.castAt = now()
		if S.tries > (Config.CastTries or 5) then
			S.tries = 0
			S.castAt = now() + 4
			setStatus(stateName(state), "Cast failed, resting")
		else
			setStatus(stateName(state), "Cast: " .. tostring(why))
		end
	end
end

--------------------------------------------------------------------------------
--  AUTO HOOK
--------------------------------------------------------------------------------
--  While "Searching" the fish bites on its own (5 -> 6 -> 7 happens with no
--  clicks), so auto hook is off by default. Turn it on if your build never
--  bites - then we click with a fixed interval.
--------------------------------------------------------------------------------

local function hookStep()
	if not Config.Hook then return end

	local state = rodState()
	if state ~= ST_SEARCHING then return end
	if not windowFocused() then return end
	if (now() - S.hookAt) < Config.HookGap then return end

	S.hookAt = now()
	pcall(mouse1click)
end

--------------------------------------------------------------------------------
--  FARM: AUTO SELL
--------------------------------------------------------------------------------

local function nearestAngler(maxDist)
	local ch = LocalPlayer.Character
	if not ch then return nil, 1e9 end
	local root = ch:FindFirstChild("HumanoidRootPart")
	if not root then return nil, 1e9 end

	if (now() - S.anglerAt) > 5 or #S.anglers == 0 then
		S.anglerAt = now()
		table.clear(S.anglers)
		local world = workspace:FindFirstChild("world")
		local npcs = world and world:FindFirstChild("npcs")
		if npcs then
			for _, npc in ipairs(npcs:GetChildren()) do
				local n = string.lower(npc.Name)
				if string.find(n, "angler", 1, true) or string.find(n, "vendor", 1, true)
					or string.find(n, "dealer", 1, true) then
					table.insert(S.anglers, npc)
				end
			end
		end
	end

	local best, bestD = nil, maxDist
	for _, npc in ipairs(S.anglers) do
		local part = npc.PrimaryPart
			or npc:FindFirstChild("HumanoidRootPart", true)
			or npc:FindFirstChild("head", true)
		if part and part:IsA("BasePart") then
			local d = (root.Position - part.Position).Magnitude
			if d < bestD then best, bestD = npc, d end
		end
	end
	return best, bestD
end

local function caughtCount()
	return tonumber(LocalPlayer:GetAttribute("FishCaughtInSession")) or 0
end

local function sellStep()
	if (Config.SellEvery or 0) <= 0 then return end

	local caught = caughtCount()
	if S.caught0 == nil then S.caught0 = caught end

	if caught <= S.caught0 then return end
	if (now() - S.sellAt) < Config.SellEvery then return end
	S.sellAt = now()

	local npc, d = nearestAngler(24)
	if not npc then
		setStatus(S.status, ("Selling: walk to an angler (%.0f studs)"):format(d))
		return
	end

	local events = ReplicatedStorage:FindFirstChild("events")
	local sell = events and events:FindFirstChild("SellAll")
	if not sell then return end

	local ok, res = pcall(function() return sell:InvokeServer() end)
	if ok and res then
		local sold = caught - (S.caught0 or caught)
		S.caught0 = caught
		notify("Xivid Hub", ("Sold %d fish at %s"):format(sold, npc.Name), "Success")
		logf("sold %d fish at %s", sold, npc.Name)
	else
		notify("Xivid Hub", "Could not sell the fish", "Error")
	end
end

--------------------------------------------------------------------------------
--  FARM: AUTO BAIT
--------------------------------------------------------------------------------
--  REMOTE RE/Bait/Equip is server side and cannot be restored from the client,
--  so the bait is equipped exactly like a player does it: by clicking the tile
--  in the backpack.
--------------------------------------------------------------------------------

local BAIT_KEEP = "Keep current"

local function refreshBaits()
	local seen = { [BAIT_KEEP] = true }
	local list = {}

	local okLib, lib = pcall(require, ReplicatedStorage.shared.modules.library.bait)
	if okLib and type(lib) == "table" then
		local okInv, inv = pcall(function()
			return DataController.InventoryReplicator:TryIndex({ "Inventory" })
		end)
		if okInv and type(inv) == "table" then
			for _, entry in pairs(inv) do
				if type(entry) == "table" and type(entry.name) == "string"
					and lib[entry.name] and not seen[entry.name] then
					seen[entry.name] = true
					table.insert(list, entry.name)
				end
			end
		end
	end

	table.sort(list)

	table.clear(S.baits)
	table.insert(S.baits, BAIT_KEEP)
	for _, n in ipairs(list) do
		table.insert(S.baits, n)
	end
	return #S.baits
end

local function currentBait()
	local stats = workspace:FindFirstChild("PlayerStats")
	local me = stats and stats:FindFirstChild(LocalPlayer.Name)
	local t = me and me:FindFirstChild(LocalPlayer.Name)
	local owner = t and t:FindFirstChild(LocalPlayer.Name)
	local st = owner and owner:FindFirstChild("Stats")
	return st and st:FindFirstChild("bait") or nil
end

--- Item names in the backpack can carry colour tags, e.g.
--- "<font color='#8bff89'>Big</font> <font ...>Prismatic</font> Sandiest Dollar"
local function plainText(s)
	if type(s) ~= "string" then return "" end
	s = s:gsub("<[^>]->", "")
	return (s:gsub("%s+", " "):match("^%s*(.-)%s*$") or "")
end

local function equipBait()
	local target = Config.Bait
	if target == BAIT_KEEP or target == "" then return false end

	local cur = currentBait()
	if cur and cur.Value == target then return true end

	local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local bp = pg and pg:FindFirstChild("backpack")
	local inv = bp and bp:FindFirstChild("inventory")
	local box = inv and inv:FindFirstChild("itemContainer")
	if not box then return false end

	local want = plainText(target):lower()
	for _, tile in ipairs(box:GetChildren()) do
		if tile:IsA("GuiButton") then
			local lbl = tile:FindFirstChild("ItemName")
			local name = plainText(lbl and lbl.Text)
			if name ~= "" and string.find(name:lower(), want, 1, true) then
				fireActivated(tile)
				return true
			end
		end
	end
	return false
end

local function baitStep()
	if not Config.AutoBait then return end
	if (now() - S.baitAt) < 8 then return end
	S.baitAt = now()

	if Config.Bait ~= BAIT_KEEP then refreshBaits() end

	local cur = currentBait()
	if Config.Bait == BAIT_KEEP then
		if cur then setStatus(S.status, "Bait: " .. tostring(cur.Value)) end
		return
	end

	if equipBait() then
		notify("Xivid Hub", "Bait equipped: " .. Config.Bait, "Success")
	else
		setStatus(S.status, "Bait \"" .. Config.Bait .. "\" is not in the backpack")
	end
end

--------------------------------------------------------------------------------
--  ISLAND TELEPORTS
--------------------------------------------------------------------------------
--  Every fast-travel door in Fisch is shut for scripts. RE/FastTravel/Teleport,
--  RF/RequestTeleportCFrame and RF/ElevatorPrompt/RequestTeleport all answer
--  without a word and leave the character exactly where it was, so the tab does
--  the one thing that does work: a plain client-side PivotTo.
--
--  The coordinates are not guesses. Every spot below is the middle of a real
--  fishing volume the game itself uses - the parts inside workspace/zones/
--  fishing, which mark where each island's fish actually are. They were read
--  out of the running game, so a cast from that point lands in the right water.
--
--  Two things are measured for every place below, and the second one is the one
--  the character is actually put down on:
--
--    x, y, z   - the middle of the real fishing volume, taken from
--                workspace/zones/fishing, so the description is honest about
--                what is going to be fished
--    sx, sy, sz - solid ground to stand on. Found by walking the character over
--                the region, waiting for the island to stream in and shooting a
--                ray down, then keeping only hits that are flat, above the water
--                and have room for a head. Or, where no shore is in casting
--                range, wy - the height the sea surface was measured at.
--
--  That second number exists because the sea is not at one height in Fisch. It
--  sits at y = 102 off Moosewood and at y = 153 over the Grand Reef, so putting
--  the character on a guessed "sea level" drops them under the surface in half
--  the map, and the oxygen runs out while the bot is still casting. Standing on
--  measured ground has no such guess in it.
--
--  Three sources are tried in order:
--    1. the table below - measured on foot, exact
--    2. the spots file - anywhere the user has already been, kept on disk
--    3. a live lookup - the island's spawn folder, its quest folder or its
--       loaded geometry, which covers the places that are in neither
--
--  Two places are marked mode = "shore" but still sit far from their volume:
--  Mineshaft and Keepers Altar. The water above them is not survivable, so
--  they land on the closest ground that is.
--
--  The spots live in their own file and not in the settings: Roblox JSONEncode
--  refuses dictionary tables, and a table keyed by island name is exactly that.
--  The file stores plain rows instead, which encode without trouble.
--------------------------------------------------------------------------------

local WATER_Y = 126  -- rough sea level, only a last-resort guess

--  mode = "shore": stand on sx, sy, sz.  mode = "water": float on the surface.
local ISLANDS = {
	{ name = "Moosewood",        zone = "Moosewood Ocean", x = 489,  y = 98,  z = 178,
	  mode = "shore", sx = 509,   sy = 172, sz = 178  },
	{ name = "Roslit Bay",        zone = "Roslit Bay",      x = -1521, y = 100, z = 518,
	  mode = "shore", sx = -1461, sy = 135, sz = 622  },
	{ name = "Roslit Pond",       zone = "Roslit Pond",     x = -1761, y = 134, z = 596,
	  mode = "shore", sx = -1751, sy = 129, sz = 613  },
	{ name = "Mushgrove",         zone = "Mushgrove Water", x = 2525, y = 119, z = -776,
	  mode = "shore", sx = 2525,  sy = 130, sz = -756 },
	{ name = "Sunstone Island",   zone = "Sunstone",        x = -846, y = 111, z = -1222,
	  mode = "shore", sx = -856,  sy = 130, sz = -1205 },
	{ name = "Terrapin Island",   zone = "Terrapin Ocean",  x = 8,    y = 56,  z = 1861,
	  mode = "shore", sx = 25,    sy = 152, sz = 1871  },
	{ name = "Forsaken Shores",   zone = "Forsaken Shores", x = -2420, y = 114, z = 1440,
	  mode = "shore", sx = -2400, sy = 147, sz = 1440  },
	{ name = "Lost Jungle",       zone = "Lost Jungle",     x = -2521, y = 127, z = -2092,
	  mode = "shore", sx = -2504, sy = 172, sz = -2082 },
	{ name = "The Arch",          zone = "The Arch",        x = 1055, y = 108, z = -1191,
	  mode = "shore", sx = 1045,  sy = 298, sz = -1208 },
	{ name = "Castaway Cliffs",   zone = "Castaway Cliffs", x = 601,  y = 145, z = -1859,
	  mode = "shore", sx = 621,   sy = 139, sz = -1859 },
}

local DEEP_SPOTS = {
	{ name = "Scallop Ocean",     zone = "Scallop Ocean",    x = 23,   y = 99,   z = 739,
	  mode = "water", wy = 103 },
	{ name = "Deep Ocean",        zone = "Deep Ocean",       x = 1978, y = 40,   z = 1150,
	  mode = "water", wy = 102 },
	{ name = "Grand Reef",        zone = "Grand Reef",       x = -3577, y = 12,  z = 542,
	  mode = "water", wy = 153 },
	{ name = "Atlantis",          zone = "Atlantean Storm",  x = -3496, y = 12,  z = 314,
	  mode = "water", wy = 102 },
	{ name = "Desolate Deep",     zone = "Desolate Deep",    x = -1561, y = -291, z = -2825,
	  mode = "water", wy = 102 },
	{ name = "Living Garden",     zone = "Living Garden",    x = -2443, y = -306, z = -2904,
	  mode = "water", wy = 99 },
	{ name = "Toxic Grove",       zone = "Toxic Grove",      x = -2564, y = -329, z = -2238,
	  mode = "water", wy = 161 },
	{ name = "Vertigo",           zone = "Vertigo",          x = -71,  y = -749, z = 1204,
	  mode = "water", wy = 102 },
	{ name = "The Depths",        zone = "The Depths",       x = 841,  y = -770, z = 1246,
	  mode = "water", wy = 102 },
	{ name = "Enchanted Crevice", zone = "Enchanted Crevice", x = 775, y = -778, z = -437,
	  mode = "water", wy = 100 },
	--  the surface of these two is not survivable: standing in it costs health
	--  and, at Keepers Altar, everything. They land on the nearest shore.
	{ name = "Mineshaft",         zone = "Mineshaft",        x = -685, y = -871, z = -110,
	  mode = "shore", sx = -485,  sy = 159, sz = -456 },
	{ name = "Keepers Altar",     zone = "Keepers Altar",    x = 1330, y = -881, z = -129,
	  mode = "shore", sx = 637,   sy = 161, sz = 271  },
}

-- one flat lookup so the console API can take a plain name
local SPOT_BY_NAME = {}
for _, list in ipairs({ ISLANDS, DEEP_SPOTS }) do
	for _, e in ipairs(list) do SPOT_BY_NAME[e.name] = e end
end

local SPOT_FILE = "spots.json"

--  { ["Roslit Bay"] = { x = .., y = .., z = .. }, ... }
local learned = {}

local function loadSpots()
	learned = {}
	if type(readfile) ~= "function" then return end
	local ok, raw = pcall(readfile, CFG_FOLDER .. "/" .. SPOT_FILE)
	if not ok or type(raw) ~= "string" or raw == "" then return end
	local ok2, rows = pcall(function() return HttpService:JSONDecode(raw) end)
	if not ok2 or type(rows) ~= "table" then return end
	for _, row in ipairs(rows) do
		if type(row) == "table" and type(row.n) == "string"
			and type(row.x) == "number" and type(row.y) == "number" and type(row.z) == "number" then
			learned[row.n] = { x = row.x, y = row.y, z = row.z }
		end
	end
	logf("spots loaded: %d", #rows)
end

local function saveSpots()
	if type(writefile) ~= "function" then return end
	local rows = {}
	for name, p in pairs(learned) do
		rows[#rows + 1] = { n = name, x = p.x, y = p.y, z = p.z }
	end
	table.sort(rows, function(a, b) return a.n < b.n end)
	local ok, json = pcall(function() return HttpService:JSONEncode(rows) end)
	if not ok then return end
	if type(isfolder) == "function" and not isfolder(CFG_FOLDER) then
		pcall(makefolder, CFG_FOLDER)
	end
	pcall(writefile, CFG_FOLDER .. "/" .. SPOT_FILE, json)
end

local function here()
	local char = LocalPlayer and LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return root and root.Position or nil
end

local function firstPart(root)
	if not root then return nil end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then return d end
	end
	return nil
end

--  Zones are trigger volumes and the sea volumes are not solid, so both are
--  switched off: a ray may only ever report real ground, otherwise it lands on
--  a zone box at y = 547 or on a palm leaf and the character is put on a roof.
local ZONES = workspace:FindFirstChild("zones")

local RAY = RaycastParams.new()
RAY.FilterType = Enum.RaycastFilterType.Exclude
RAY.IgnoreWater = true

local function castFrom(origin, dir)
	RAY.FilterDescendantsInstances = { ZONES, workspace.CurrentCamera }
	return workspace:Raycast(origin, dir, RAY)
end

--  Height of the first solid surface under a point, or nil over open water
local function groundY(x, z)
	local hit = castFrom(Vector3.new(x, 600, z), Vector3.new(0, -2000, 0))
	if not hit then return nil end
	local p = hit.Instance
	if not p:IsA("BasePart") or not p.CanCollide then return nil end
	return hit.Position.Y
end

--  Good enough to stand on: mostly the same height, and nothing overhead
local function standable(x, y, z)
	local n = 0
	for _, dx in ipairs({ 0, 6, -6 }) do
		for _, dz in ipairs({ 0, 6, -6 }) do
			local h = groundY(x + dx, z + dz)
			if h and math.abs(h - y) < 7 then n = n + 1 end
		end
	end
	if n < 6 then return false end
	return castFrom(Vector3.new(x, y + 3, z), Vector3.new(0, 14, 0)) == nil
end

--  Walks outwards in rings and takes the first patch of ground worth standing
--  on. Only reached when a measured point turns out to be unusable, so the
--  cost of a few thousand rays does not matter.
local LAND_RINGS = { 0, 20, 40, 60, 90, 120, 160, 200, 260, 320, 400, 500, 650, 800, 1000 }

local function findLanding(cx, cz)
	for _, r in ipairs(LAND_RINGS) do
		local steps = (r == 0) and 1 or 12
		for i = 0, steps - 1 do
			local a = (i / steps) * math.pi * 2
			local x = cx + math.cos(a) * r
			local z = cz + math.sin(a) * r
			local y = groundY(x, z)
			if y and y > (WATER_Y - 40) and standable(x, y, z) then
				logf("landing point found at %d,%d,%d (ring %d)", x, y, z, r)
				return Vector3.new(x, y + 4, z)
			end
		end
	end
	return nil
end

--  Looked up in the live world, for the islands that are in no table
local function liveSpot(e)
	local world = workspace:FindFirstChild("world")
	if world then
		--  the island's own spawn or quest folder, when the game has streamed it in
		local spawns = world:FindFirstChild("spawns")
		local part = firstPart(spawns and spawns:FindFirstChild(e.name))
			or firstPart(Controllers:FindFirstChild("Locations")
				and Controllers.Locations:FindFirstChild(e.name))
		if part then
			logf("live spot for %s from %s", e.name, part:GetFullName())
			return part.Position
		end

		--  the middle of whatever geometry of the island is loaded right now
		local map = world:FindFirstChild("map")
		map = map and map:FindFirstChild(e.name)
		if map then
			local n, sx, sz = 0, 0, 0
			for _, c in ipairs(map:GetDescendants()) do
				if c:IsA("BasePart") and (c.Position.Y + c.Size.Y / 2) > (WATER_Y + 2) then
					n = n + 1
					sx = sx + c.Position.X
					sz = sz + c.Position.Z
				end
			end
			if n >= 4 then
				logf("live spot for %s from %d loaded parts", e.name, n)
				return Vector3.new(sx / n, WATER_Y + 6, sz / n)
			end
		end
	end

	--  finally a fishing volume that carries the island's name
	local zones = workspace:FindFirstChild("zones")
	zones = zones and zones:FindFirstChild("fishing")
	if zones then
		for _, c in ipairs(zones:GetChildren()) do
			if c:IsA("BasePart") and c.Name == e.zone then return c.Position end
		end
	end
	return nil
end

--  The point the character is actually put down on
local function standFor(e)
	--  measured ground, or the surface above a volume with no shore
	if e.sx then
		return Vector3.new(e.sx, e.sy + 4, e.sz)
	end
	if e.mode == "water" then
		return Vector3.new(e.x, (e.wy or WATER_Y) + 6, e.z)
	end

	--  nowhere in the tables: the file first, then the running world
	local saved = learned[e.name]
	if saved then return Vector3.new(saved.x, saved.y, saved.z) end
	return liveSpot(e)
end

local function rememberSpot(name, v)
	learned[name] = { x = v.X, y = v.Y, z = v.Z }
end

--  Two and a half seconds of tidying up after a jump, fixing the two ways a
--  PivotTo can go wrong. Standing on real ground the first branch does nothing,
--  because the ground under the feet is already below the character:
--    inside a hillside - the ray finds ground above the feet, so the character
--      is put on top of that surface rather than in the middle of it
--    sinking in open water - there is nothing at all underfoot, so the character
--      is put back on the surface it arrived at
local function settle()
	local char = LocalPlayer and LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local top = root.Position.Y
	for _ = 1, 25 do
		task.wait(0.1)
		local live = LocalPlayer and LocalPlayer.Character
		if not root.Parent or not live
			or root ~= live:FindFirstChild("HumanoidRootPart") then return end

		local p = root.Position
		if p.Y > top then top = p.Y end

		local y = groundY(p.X, p.Z)
		local want
		if y and y > (p.Y + 1) then
			want = CFrame.new(p.X, y + 4, p.Z)
		elseif not y and Config.TpFloat and p.Y < (top - 12) then
			want = CFrame.new(p.X, top, p.Z)
		end

		if want and (root.CFrame.Position - want.Position).Magnitude > 2 then
			char:PivotTo(want)
			root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			top = want.Position.Y
		end
	end
end

--  Holds the character on the surface while they are over deep water, so a dive
--  that was not asked for never ends with the oxygen running out. Off, if a dive
--  is exactly what is wanted.
local function floatLoop()
	while S.unlocked do
		if Config.TpFloat and (S.floatTop or 0) > 0 then
			local char = LocalPlayer and LocalPlayer.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root then
				local p = root.Position
				if p.Y < (S.floatTop - 15) and not groundY(p.X, p.Z) then
					char:PivotTo(CFrame.new(p.X, S.floatTop, p.Z))
					root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
					logf("floated back to the surface at y=%.0f", S.floatTop)
				end
			end
		end
		task.wait(0.5)
	end
end

--  Moves the character and reports what happened, so a button can say it out loud
local function travelTo(name)
	local e = SPOT_BY_NAME[name]
	if not e then return false, "There is no place called \"" .. tostring(name) .. "\"" end

	local char = LocalPlayer and LocalPlayer.Character
	if not char then return false, "No character yet" end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return false, "The character is dead" end

	local stand = standFor(e)
	if not stand then
		return false, "No spot data for " .. name .. " - visit the island once and it is remembered"
	end

	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return false, "No HumanoidRootPart" end

	char:PivotTo(CFrame.new(stand.X, stand.Y, stand.Z))
	--  the old velocity would slide the character straight back off
	root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
	if root:IsA("BasePart") then
		root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
	end

	--  only a water destination arms the float: on land the ray finds ground
	--  and the loop has nothing to do
	S.floatTop = (e.mode == "water") and stand.Y or 0

	rememberSpot(e.name, stand)
	saveSpots()
	task.spawn(settle)
	setStatus("Travelling", name)
	logf("teleport %s -> %.0f,%.0f,%.0f (%s)", e.name, stand.X, stand.Y, stand.Z, e.mode)
	return true, name
end

--  One honest line per button
local function descFor(e)
	if e.mode == "water" then
		return string.format("No shore in casting range, so you float on the surface "
			.. "above a volume %d below it", math.abs(e.y - (e.wy or WATER_Y)))
	end
	if e.sx then
		local d = math.sqrt((e.sx - e.x) ^ 2 + (e.sz - e.z) ^ 2)
		if d > 250 then
			return string.format("The water above this volume is not survivable, so you are "
				.. "put down on the nearest shore, %d studs away", math.floor(d))
		end
		return "Shore of " .. e.name .. " - you are put down on solid ground"
	end
	return "Where you were standing when you visited " .. e.name
end

--------------------------------------------------------------------------------
--  MAIN LOOP
--------------------------------------------------------------------------------

local function tick()
	-- nothing runs behind the gate, whatever F5 or the console says
	if not S.unlocked then
		reelRelease()
		if S.status ~= "Locked" then setStatus("Locked", "Enter the access key in the window") end
		return
	end

	if not Config.Enabled then
		reelRelease()
		if S.status ~= "Disabled" then setStatus("Disabled") end
		return
	end

	S.note = ""
	local state = rodState()
	setStatus(state and stateName(state) or "No rod")

	if Config.Cast  then castStep() end
	if Config.Shake then shakeStep() end
	if Config.Reel  then reelStep()  else reelRelease() end
	if Config.Hook  then hookStep()  end
	if Config.Farm  then
		if (Config.SellEvery or 0) > 0 then sellStep() end
		baitStep()
	end
end

--------------------------------------------------------------------------------
--  READINESS (wait for the world to load)
--------------------------------------------------------------------------------

local function waitReady()
	local tries = 0
	while tries < 120 do
		tries = tries + 1
		local ok = pcall(function()
			assert(LocalPlayer.Character)
			assert(ReplicatedStorage:FindFirstChild("client"))
			assert(ReplicatedStorage:FindFirstChild("packages"))
		end)
		if ok then return true end
		task.wait(0.5)
	end
	return false
end

--------------------------------------------------------------------------------
--  SETTINGS FILE
--------------------------------------------------------------------------------

local function saveConfig()
	if type(writefile) ~= "function" then return end
	local payload = {}
	for k, v in pairs(Config) do
		if type(v) ~= "function" then payload[k] = v end
	end
	local ok, json = pcall(function() return HttpService:JSONEncode(payload) end)
	if not ok then return end
	if type(isfolder) == "function" and not isfolder(CFG_FOLDER) then
		pcall(makefolder, CFG_FOLDER)
	end
	pcall(writefile, CFG_FOLDER .. "/" .. CFG_FILE, json)
	logf("settings saved")
end

local function loadConfig()
	if type(readfile) ~= "function" then return end
	local ok, raw = pcall(readfile, CFG_FOLDER .. "/" .. CFG_FILE)
	if not ok or type(raw) ~= "string" or raw == "" then return end
	local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
	if not ok2 or type(data) ~= "table" then return end
	for k, v in pairs(data) do
		if Config[k] ~= nil and type(v) == type(Config[k]) then
			Config[k] = v
		end
	end
	Config.Enabled = false
	logf("settings loaded")
end

local DEFAULTS = {}
for k, v in pairs(Config) do DEFAULTS[k] = v end

local function resetConfig()
	for k, v in pairs(DEFAULTS) do Config[k] = v end
	Config.Enabled = false
	logf("settings reset to defaults")
end

--------------------------------------------------------------------------------
--  AUDIO
--------------------------------------------------------------------------------
--  Built-in engine sounds only (rbxasset://) plus two tiny asset ids, so the
--  sounds work offline and never 404. They are preloaded in the background so
--  the very first click is not silent.
--------------------------------------------------------------------------------

local SFX_SRC = {
	Click  = "rbxassetid://130113322",           -- any press
	Switch = "rbxasset://sounds/switch.wav",     -- toggle on / dropdown
	Off    = "rbxasset://sounds/electronicpingshort.wav", -- toggle off
	Tick   = "rbxassetid://421058925",           -- slider ticks
	Splash = "rbxasset://sounds/impact_water.mp3", -- fish caught
	Done   = "rbxasset://sounds/button.wav",     -- success
}

local SFX = {}
local lastTick = 0

local function sfxLoad()
	-- a reload must not leave the templates of the previous run in SoundService
	for _, c in ipairs(SoundService:GetChildren()) do
		if c:IsA("Sound") and string.sub(c.Name, 1, 11) == "AutoFishSFX" then
			pcall(function() c:Destroy() end)
		end
	end
	for name, id in pairs(SFX_SRC) do
		if not SFX[name] then
			local s = Instance.new("Sound")
			s.Name = "AutoFishSFX_" .. name
			s.SoundId = id
			s.Volume = 0
			s.Parent = SoundService
			SFX[name] = s
			task.spawn(function()
				pcall(function() ContentProvider:PreloadAsync({ s }) end)
			end)
		end
	end
end

local function sfx(name, mul)
	if not Config.Sound then return end
	local t = SFX[name]
	if not t then return end
	local v = (tonumber(Config.Volume) or 0.35) * (mul or 1)
	if v <= 0.001 then return end
	if name == "Tick" then
		local nt = now()
		if nt - lastTick < 0.06 then return end
		lastTick = nt
	end
	local c = t:Clone()
	c.Volume = math.clamp(v, 0, 1)
	c.Parent = SoundService
	pcall(function() c:Play() end)
	task.delay(4, function()
		if c and c.Parent then pcall(function() c:Destroy() end) end
	end)
end

--------------------------------------------------------------------------------
--  THEME: NEON STYLE ENGINE
--------------------------------------------------------------------------------
--  WindUI only allows ONE window per library instance and its Destroy() wipes
--  the shared ScreenGui, so every script start loads a FRESH copy of the
--  library - that one has its own ScreenGui and an empty window slot.
--------------------------------------------------------------------------------

local ACCENTS = {
	Cyan    = Color3.fromRGB(0, 229, 255),
	Magenta = Color3.fromRGB(255, 45, 170),
	Red     = Color3.fromRGB(255, 45, 70),
	Crimson = Color3.fromRGB(255, 20, 110),
	Pink    = Color3.fromRGB(255, 105, 180),
	Purple  = Color3.fromRGB(175, 110, 255),
	Violet  = Color3.fromRGB(130, 80, 255),
	Indigo  = Color3.fromRGB(90, 110, 255),
	Blue    = Color3.fromRGB(60, 150, 255),
	Green   = Color3.fromRGB(40, 235, 120),
	Lime    = Color3.fromRGB(140, 255, 90),
	Teal    = Color3.fromRGB(0, 230, 190),
	Gold    = Color3.fromRGB(255, 205, 60),
	Orange  = Color3.fromRGB(255, 140, 40),
}
local ACCENT_ORDER = {
	"Cyan", "Magenta", "Red", "Crimson", "Pink",
	"Purple", "Violet", "Indigo", "Blue",
	"Green", "Lime", "Teal", "Gold", "Orange",
}

local FONTS = {
	-- clean, modern
	"GothamBlack", "GothamBold", "Gotham", "BuilderSansExtraBold", "Sarpanch",
	-- techno
	"Michroma", "SciFi", "Code", "TitilliumWeb",
	-- retro / display
	"Highway", "Arcade", "FredokaOne", "GrenzeGotisch",
}

local function accentColor() return ACCENTS[Config.Accent] or ACCENTS.Cyan end
local function fontEnum()   return Enum.Font[Config.Font] or Enum.Font.GothamBlack end

--- An old settings file may name a colour or a font that no longer exists
local function sanitizeStyle()
	if not ACCENTS[Config.Accent] then Config.Accent = "Cyan" end
	local found = false
	for _, f in ipairs(FONTS) do
		if f == Config.Font then found = true break end
	end
	if not found then Config.Font = "GothamBlack" end
	Config.GlowLevel = math.clamp(tonumber(Config.GlowLevel) or 0.7, 0, 1)
	Config.Volume    = math.clamp(tonumber(Config.Volume) or 0.35, 0, 1)
end

--- Text glow transparency. mul 0.55 = idle, 0.8 = hover, 1 = pressed
local function glowTrans(mul)
	if not Config.Glow then return 1 end
	local lvl = math.clamp(tonumber(Config.GlowLevel) or 0.7, 0, 1)
	return math.clamp(1 - lvl * 0.85 * (mul or 0.55), 0, 1)
end

local INTERACTIVE = {
	Toggle = true, Slider = true, Button = true, Dropdown = true,
	Colorpicker = true, Input = true, Keybind = true, ProgressBar = true,
}

local STYLE = { items = {} }   -- root Instance -> { stroke, texts, scale, hot }
local prevAccent = nil

local function tweenStroke(stroke, trans, thick, speed)
	if not stroke then return end
	pcall(function()
		TweenService:Create(stroke, TweenInfo.new(
			speed or 0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Transparency = trans, Thickness = thick }):Play()
	end)
end

local function tweenTexts(entry, trans, speed)
	if not entry then return end
	for _, t in ipairs(entry.texts) do
		pcall(function()
			TweenService:Create(t, TweenInfo.new(speed or 0.16),
				{ TextStrokeTransparency = trans }):Play()
		end)
	end
end

local function tweenScale(scale, value)
	if not scale or not Config.Anim then return end
	pcall(function()
		TweenService:Create(scale,
			TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = value }):Play()
	end)
end

local function styleText(d)
	pcall(function() d.Font = fontEnum() end)
	pcall(function()
		d.TextStrokeColor3 = accentColor()
		d.TextStrokeTransparency = glowTrans(0.55)
	end)
end

--- WindUI builds part of the interface lazily (sidebar, tab names, dropdowns),
--- so the font/glow pass is repeated for a while instead of running once.
local function fontPass(root, force)
	if not root then return end
	local font, a, tr = fontEnum(), accentColor(), glowTrans(0.55)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
			if force or d:GetAttribute("__afFont") ~= Config.Font then
				pcall(function() d.Font = font end)
				pcall(function()
					d.TextStrokeColor3 = a
					d.TextStrokeTransparency = tr
				end)
				d:SetAttribute("__afFont", Config.Font)
			end
		end
	end
end

local GUI_KEYS = { "ScreenGui", "NotificationGui", "DropdownGui", "TooltipGui" }

local function applyFontEverywhere(force)
	local lib = _G.__AutoFishUILib
	if type(lib) ~= "table" then return end
	for _, key in ipairs(GUI_KEYS) do
		fontPass(lib[key], force)
	end
end

--- Gives one WindUI element the neon look and wires press feedback
local function decorate(el)
	if type(el) ~= "table" then return end
	local root = el.ElementFrame
	if not root then return end
	local ok, isGui = pcall(function() return root:IsA("GuiObject") end)
	if not ok or not isGui then return end
	if STYLE.items[root] then return end

	local entry = { texts = {}, hot = INTERACTIVE[el.__type] or false }
	STYLE.items[root] = entry

	local font = fontEnum()
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
			styleText(d)
			pcall(function() d.Font = font end)
			table.insert(entry.texts, d)
		end
	end

	if not entry.hot then return end

	local stroke = root:FindFirstChildOfClass("UIStroke")
	if not stroke then stroke = Instance.new("UIStroke") end
	stroke.Name = "__afStroke"
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Thickness = 1.2
	stroke.Color = accentColor()
	stroke.Transparency = 0.85
	stroke.Parent = root
	entry.stroke = stroke

	local scale = root:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = root
	end
	scale.Name = "__afScale"
	entry.scale = scale

	pcall(function() root.MouseEnter:Connect(function()
		tweenStroke(stroke, 0.5, 1.6)
		tweenTexts(entry, glowTrans(0.8))
	end) end)

	pcall(function() root.MouseLeave:Connect(function()
		tweenStroke(stroke, 0.85, 1.2)
		tweenTexts(entry, glowTrans(0.55))
		tweenScale(scale, 1)
	end) end)

	pcall(function() root.MouseButton1Down:Connect(function()
		tweenStroke(stroke, 0, 2.4, 0.09)
		tweenTexts(entry, glowTrans(1), 0.09)
		tweenScale(scale, 0.975)
		sfx("Click", 0.8)
	end) end)

	pcall(function() root.MouseButton1Up:Connect(function()
		tweenStroke(stroke, 0.5, 1.6)
		tweenTexts(entry, glowTrans(0.8))
		tweenScale(scale, 1)
	end) end)
end

local function near(c, ref, tol)
	return math.abs(c.R - ref.R) + math.abs(c.G - ref.G) + math.abs(c.B - ref.B) < tol
end

--- Re-tints every baked-in theme colour from the old accent to the new one
local function recolorGui(root, from, to)
	if not root or not from then return end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("GuiObject") then
			if near(d.BackgroundColor3, from, 0.12) then d.BackgroundColor3 = to end
			if near(d.BorderColor3, from, 0.12) then d.BorderColor3 = to end
			if d:IsA("ImageLabel") and near(d.ImageColor3, from, 0.12) then
				d.ImageColor3 = to
			end
			if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
				if near(d.TextColor3, from, 0.12) then d.TextColor3 = to end
			end
		elseif d:IsA("UIGradient") then
			-- a gradient holds a ColorSequence, so every keypoint is checked
			local seq = d.Color
			if type(seq) == "ColorSequence" then
				for _, kp in ipairs(seq.Keypoints) do
					if near(kp.Value, from, 0.12) then kp.Value = to end
				end
			end
		elseif d:IsA("UIStroke") then
			if near(d.Color, from, 0.12) then d.Color = to end
		end
	end
end

--- Re-applies the look after the user changed accent / font / glow
local function applyStyle()
	local a = accentColor()
	local font = fontEnum()

	for _, entry in pairs(STYLE.items) do
		if entry.stroke and entry.stroke.Parent then entry.stroke.Color = a end
		for _, t in ipairs(entry.texts) do
			pcall(function()
				t.Font = font
				t.TextStrokeColor3 = a
				t.TextStrokeTransparency = glowTrans(0.55)
			end)
		end
	end

	local lib = _G.__AutoFishUILib
	if type(lib) == "table" then
		pcall(function()
			if lib.ScreenGui then recolorGui(lib.ScreenGui, prevAccent, a) end
		end)
		local th = lib.Themes and lib.Themes.Neon
		if th then
			th.Accent, th.Primary, th.Slider = a, a, a
			th.Checkbox, th.Toggle, th.Outline = a, a, a
		end
	end
	prevAccent = a
	applyFontEverywhere(true)
end

--------------------------------------------------------------------------------
--  WindUI LOADER
--------------------------------------------------------------------------------
--  Three ways to get the library, in this order:
--    1. a copy already sitting next to the script
--    2. the copies listed in WINDUI_URLS (host windui.lua once, anywhere)
--    3. nothing worked -> the menu reports it instead of failing silently
--  The URL list is empty on purpose: drop your own link in and the script is
--  shareable as a single small file.
--------------------------------------------------------------------------------

local WINDUI_URLS = {
	-- "https://catbox.moe/user/file/xxxxxxx.lua",
	-- "https://0x0.st/xxxxxx.lua",
}

local WINDUI_LOCAL = {
	"ui-libraries/windui.lua", "WindUI/windui.lua", "windui.lua", "WindUI.lua",
}

-- Executors do not agree on the request signature: some want a plain URL
-- string, others want a table and answer with a table, some answer with the
-- body itself. Every known shape is tried, so the script does not care which
-- executor it runs on.
local function pickBody(res)
	if type(res) == "string" and #res > 1000 then
		return res
	end
	if type(res) == "table" then
		local b = res.Body or res.body or res.content or res.text
		if type(b) == "string" and #b > 1000 then
			return b
		end
	end
	return nil
end

local function httpGet(url)
	if type(url) ~= "string" or url == "" then return nil end
	local body = nil

	-- 1. request(url)
	if type(request) == "function" then
		local ok, res = pcall(request, url)
		if ok then body = pickBody(res) end
	end

	-- 2. request({ Url = ..., Method = "GET" })
	if not body and type(request) == "function" then
		local ok, res = pcall(request, { Url = url, Method = "GET" })
		if ok then body = pickBody(res) end
	end

	-- 3. the Roblox HTTP service
	if not body then
		local ok, res = pcall(function()
			return game:GetService("HttpService"):RequestAsync({
				Url = url, Method = "GET",
			}).Body
		end)
		if ok then body = pickBody(res) end
	end

	-- 4. game:HttpGet
	if not body then
		local ok, res = pcall(function() return game:HttpGet(url) end)
		if ok then body = pickBody(res) end
	end

	return body
end

-- a string that turns into a working library
local function useLib(content)
	local ok, chunk = pcall(loadstring, content)
	if not ok or type(chunk) ~= "function" then return nil end
	local ok2, lib = pcall(chunk)
	if ok2 and type(lib) == "table" and lib.CreateWindow and not lib.Window then
		_G.WindUI = lib
		return lib
	end
	return nil
end

local function loadWindUI(force)
	if not force and type(_G.WindUI) == "table" and _G.WindUI.CreateWindow then
		return _G.WindUI
	end
	if type(loadstring) ~= "function" then return nil end

	-- 1. a copy on disk
	if type(readfile) == "function" then
		for _, path in ipairs(WINDUI_LOCAL) do
			local ok, content = pcall(readfile, path)
			if ok and type(content) == "string" and #content > 1000 then
				local lib = useLib(content)
				if lib then
					logf("WindUI loaded from %s", path)
					return lib
				end
			end
		end
	end

	-- 2. a hosted copy
	for _, url in ipairs(WINDUI_URLS) do
		if type(url) == "string" and url ~= "" then
			local content = httpGet(url)
			if content then
				local lib = useLib(content)
				if lib then
					logf("WindUI downloaded from %s", url)
					return lib
				end
			end
		end
	end
	return nil
end

--- Removes the previous copy's screens so they do not hang around in CoreGui
local function killOldUI()
	local old = _G.__AutoFishWindow
	if type(old) == "table" and not old.Destroyed and type(old.Destroy) == "function" then
		pcall(function() old:Destroy() end)
	end
	_G.__AutoFishWindow = nil

	local lib = _G.__AutoFishUILib
	if type(lib) == "table" then
		for _, key in ipairs({ "ScreenGui", "NotificationGui", "DropdownGui", "TooltipGui" }) do
			pcall(function() lib[key]:Destroy() end)
		end
	end
	_G.__AutoFishUILib = nil
	_G.WindUI = nil

	table.clear(STYLE.items)
	prevAccent = nil
end

--- Builds a dark theme tinted with the neon accent
local function neonTheme(WindUI)
	local base = (WindUI.Themes and (WindUI.Themes[Config.Theme] or WindUI.Themes.Dark)) or nil
	local t = {}
	if base then
		for k, v in pairs(base) do t[k] = v end
	end
	local a = accentColor()
	t.Name          = "Neon"
	t.Accent        = a
	t.Primary       = a
	t.Slider        = a
	t.Checkbox      = a
	t.Toggle        = a
	t.Outline       = a
	t.Background    = Color3.fromRGB(10, 10, 16)
	t.PanelBackground = Color3.fromRGB(15, 15, 24)
	t.ElementBackground = Color3.fromRGB(24, 24, 36)
	t.Text          = Color3.fromRGB(232, 238, 255)
	t.Icon          = Color3.fromRGB(150, 160, 195)
	t.Placeholder   = Color3.fromRGB(120, 130, 165)
	if WindUI.Themes then WindUI.Themes.Neon = t end
	return t
end

--------------------------------------------------------------------------------
--  ACCESS KEY ENGINE
--------------------------------------------------------------------------------
--  Everything the menu builds is remembered in S.lockList, so the whole window
--  can be hidden behind the gate with one pass and revealed again after a
--  correct key. The state lives in S, never in Config, so nothing is saved.
--------------------------------------------------------------------------------

local keyInput   = nil   -- the WindUI Input widget
local keyBg      = nil   -- its background colour, kept to flash red on a miss
local keyTimer   = nil   -- pending "undo the red flash" handle
local keyPending = nil   -- a key handed over before the menu finished loading

-- put the invite on the clipboard (silent = no notification, used on boot)
local function copyInvite(silent)
	local ok = false
	if type(setclipboard) == "function" then
		ok = pcall(setclipboard, DISCORD_LINK)
	end
	if not silent then
		if ok then
			notify("Xivid Hub", "Invite copied to the clipboard", "Success")
			sfx("Switch")
		else
			notify("Xivid Hub", "Copy it by hand: " .. DISCORD_LINK, "Error")
		end
	end
	return ok
end

-- compare every single character, no early exit: a wrong guess costs the same
-- as the right one, and the answer is never a plain string match.
-- Case does not matter, so the key can be typed or pasted in any form.
local function keyMatches(typed)
	local a = string.upper(tostring(typed or ""))
	local b = string.upper(tostring(ACCESS_KEY or ""))
	if #a ~= #b then return false end
	local diff = 0
	for i = 1, #a do
		diff = diff + (a:byte(i) ~= b:byte(i) and 1 or 0)
	end
	return diff == 0
end

-- read the text straight out of the TextBox: WindUI only commits its Value on
-- focus lost, which may not have happened when Unlock is pressed. Spaces are
-- dropped, so "X3gk DN" opens the menu just as well.
local function readKey()
	if not keyInput or not keyInput.ElementFrame then return "" end
	for _, d in ipairs(keyInput.ElementFrame:GetDescendants()) do
		if d:IsA("TextBox") then
			return (string.gsub(d.Text or "", "%s", ""))
		end
	end
	return ""
end

local function frameIs(list, f)
	for _, x in ipairs(list) do
		if x == f then return true end
	end
	return false
end

-- locked = true shows only the gate, locked = false shows the whole menu
local function setLocked(locked)
	S.unlocked = not locked
	for _, el in ipairs(S.lockList) do
		local f = el and el.ElementFrame
		if f and f.Parent then
			local isKey  = frameIs(S.keyFrames, f)
			local isHint = frameIs(S.hintFrames, f)
			-- a plain "a and b or c" would be wrong here: when the gate frame
			-- is one of the two, the fall-through branch would win
			local want
			if locked then
				want = isKey or isHint
			else
				want = (not isKey) and (not isHint)
			end
			pcall(function() f.Visible = want end)
		end
	end
	if not locked then
		S.note = ""
		if S.status == "Locked" then setStatus("Disabled") end
	end
	logf("menu %s", locked and "locked" or "unlocked")
end

local function flashKeyFrame(ok)
	if not keyInput then return end
	local frame = keyInput.InputFrame or keyInput.ElementFrame
	if not frame then return end
	local want = ok and (accentColor() or Color3.fromRGB(80, 220, 255))
		or Color3.fromRGB(255, 70, 90)
	pcall(function() frame.BackgroundColor3 = want end)
	if keyTimer then pcall(function() keyTimer:cancel() end) end
	keyTimer = task.delay(0.45, function()
		if keyBg then pcall(function() frame.BackgroundColor3 = keyBg end) end
	end)
end

local function tryUnlock(override)
	local typed = readKey()
	-- the console may hand the key over before the menu is up
	if typed == "" then
		typed = tostring(override or keyPending or "")
	end
	if typed == "" then
		notify("Xivid Hub", "Paste the key you got in the Discord server", "Error")
		sfx("Off")
		flashKeyFrame(false)
		return
	end

	if not keyMatches(typed) then
		keyPending = nil
		S.badKey = S.badKey + 1
		setStatus("Locked", ("%d wrong attempt(s) - the key comes from the Discord server"):format(S.badKey))
		notify("Xivid Hub", "Wrong key. Join the Discord server to get the right one", "Error")
		sfx("Off")
		flashKeyFrame(false)
		logf("key rejected (attempt %d)", S.badKey)
		return
	end

	flashKeyFrame(true)
	sfx("Done")
	setLocked(false)
	notify("Xivid Hub", "Key accepted - welcome!", "Success")
	logf("key accepted")
end

--------------------------------------------------------------------------------
--  INTERFACE
--------------------------------------------------------------------------------

local errors = {}

local function buildUI()
	_G.__AutoFishErrors = errors
	_G.__AutoFishUI = "starting"
	local WindUI, window

	-- a few attempts in case an old library copy still holds the window slot
	for attempt = 1, 3 do
		killOldUI()
		WindUI = loadWindUI(true)
		if not WindUI then
			errors[#errors + 1] = "WindUI not found"
			_G.__AutoFishUI = "WindUI failed to load"
			return
		end
		_G.__AutoFishUILib = WindUI

		neonTheme(WindUI)
		prevAccent = accentColor()

		local wok, werr = pcall(function()
			window = WindUI:CreateWindow({
				Title  = "Xivid Hub",
				Folder = CFG_FOLDER,
				Theme  = "Neon",
				Size   = UDim2.fromOffset(600, 500),
			})
		end)
		if not wok then
			errors[#errors + 1] = "CreateWindow: " .. tostring(werr)
			window = nil
		end
		if type(window) ~= "table" and type(WindUI.Window) == "table" then
			window = WindUI.Window
		end
		if type(window) == "table" and not window.Destroyed then
			_G.__AutoFishUI = "window created"
			break
		end
		errors[#errors + 1] = ("attempt %d: window not created"):format(attempt)
		window = nil
	end

	if type(window) ~= "table" then
		_G.__AutoFishUI = "window not created"
		warn("[AutoFish] UI: the WindUI window could not be created")
		return
	end
	_G.__AutoFishWindow = window

	pcall(function()
		S.notify = function(o) WindUI:Notify(o) end
	end)
	sfxLoad()

	-- everything lives in one tab now: fishing, minigames and farming
	local farmT, tpT, themeT, optT

	pcall(function() farmT  = window:Tab({ Title = "Farming" }) end)
	pcall(function() tpT    = window:Tab({ Title = "Teleports" }) end)
	pcall(function() themeT = window:Tab({ Title = "Theme" }) end)
	pcall(function() optT   = window:Tab({ Title = "Settings" }) end)

	if not farmT then
		errors[#errors + 1] = "tabs not created"
		return
	end

	-- Safe wrapper: one bad widget line never takes the whole window down.
	-- It also wires the interface sound to every widget kind.
	local function add(section, kind, opts)
		if not section then
			errors[#errors + 1] = kind .. ": no section"
			return nil
		end
		local fn = section[kind]
		if type(fn) ~= "function" then
			errors[#errors + 1] = kind .. ": method missing"
			return nil
		end

		local cb = opts.Callback
		if kind == "Toggle" then
			opts.Callback = function(v)
				local wasOn = Config.Sound
				if cb then cb(v) end
				if wasOn then sfx(v and "Switch" or "Off") end
			end
		elseif kind == "Button" then
			opts.Callback = function(...)
				local wasOn = Config.Sound
				if cb then cb(...) end
				if wasOn then sfx("Click") end
			end
		elseif kind == "Slider" then
			opts.Callback = function(v)
				sfx("Tick", 0.55)
				if cb then cb(v) end
			end
		elseif kind == "Dropdown" then
			opts.Callback = function(...)
				sfx("Switch")
				if cb then cb(...) end
			end
		end

		local ok, res = pcall(fn, section, opts)
		if not ok then
			errors[#errors + 1] = kind .. " " .. tostring(opts.Title) .. ": " .. tostring(res)
			return nil
		end
		decorate(res)
		-- every widget goes into the registry, so the key gate can hide the
		-- whole menu in one pass
		if res then S.lockList[#S.lockList + 1] = res end
		return res
	end

	-- mark a widget as part of the gate itself (shown while locked)
	local function markKey(el)
		if el and el.ElementFrame then S.keyFrames[#S.keyFrames + 1] = el.ElementFrame end
		return el
	end

	-- mark a widget as a lock note (shown while locked, hidden afterwards)
	local function markHint(el)
		if el and el.ElementFrame then S.hintFrames[#S.hintFrames + 1] = el.ElementFrame end
		return el
	end

	--------------------------------------------------------------------------
	--  The gate: the Discord invite, the key field and the unlock button
	--------------------------------------------------------------------------
	local sKey = markKey(add(farmT, "Section", {
		Title = "Access key",
		Desc  = "Join the Discord server to get the key - the invite was copied to your clipboard when this script ran",
	}))
	markKey(add(sKey, "Paragraph", {
		Title = "Discord",
		Desc  = DISCORD_LINK,
	}))
	markKey(add(sKey, "Button", {
		Title    = "Copy the invite",
		Desc     = "Puts the link back on the clipboard",
		Callback = function() copyInvite(false) end,
	}))
	keyInput = add(sKey, "Input", {
		Title       = "Key",
		Desc        = "Paste the key here",
		Placeholder = "XXXXXX",
		Width       = 200,
		Value       = "",
	})
	markKey(keyInput)
	markKey(add(sKey, "Button", {
		Title    = "Unlock",
		Desc     = "Checks the key and opens the menu",
		Callback = tryUnlock,
	}))
	markKey(add(sKey, "Paragraph", {
		Title = "How to get the key",
		Desc  = "1. Open Discord and paste the invite from the clipboard\n"
		      .. "2. Read the key from the #keys channel\n"
		      .. "3. Paste it above and press Unlock\n"
		      .. "The key is asked again every time you run the script.",
	}))

	--------------------------------------------------------------------------
	--  Farming: the master switch, live status, casting, minigames, selling
	--------------------------------------------------------------------------
	local sMain = add(farmT, "Section", {
		Title = "Auto Fishing",
		Desc  = "Master switch for the whole bot",
	})
	add(sMain, "Toggle", {
		Title = "Auto Fishing", Value = Config.Enabled,
		Desc  = "Master switch (F5)",
		Callback = function(v)
			Config.Enabled = v
			S.caught0 = nil
			setStatus(v and "Enabled" or "Disabled")
			if v then
				notify("Xivid Hub", "Auto fishing enabled", "Success")
				sfx("Done")
			end
		end,
	})

	-- a heading plus a thin line (this WindUI version draws no title on a
	-- divider, so the heading is a paragraph of its own)
	add(farmT, "Paragraph", { Title = "Live status" })
	add(farmT, "Divider", {})

	local sInfo = add(farmT, "Section", { Title = "Status" })
	local lblState = add(sInfo, "Paragraph", { Title = "Rod" })
	local lblReel  = add(sInfo, "Paragraph", { Title = "Reel" })
	local lblCast  = add(sInfo, "Paragraph", { Title = "Casting" })
	local lblFarm  = add(sInfo, "Paragraph", { Title = "Session" })
	local barReel  = add(sInfo, "ProgressBar", {
		Title = "Reel progress",
		Value = { Min = 0, Max = 100, Default = 0 },
		ShowValue = true,
	})

	--------------------------------------------------------------------------
	--  Auto cast
	--------------------------------------------------------------------------
	local sCast = add(farmT, "Section", {
		Title = "Auto cast",
		Desc  = "Sends RF/FishingRod/Cast - works while minimized",
	})
	add(sCast, "Toggle", {
		Title = "Auto cast", Value = Config.Cast,
		Callback = function(v) Config.Cast = v end,
	})
	add(sCast, "Slider", {
		Title = "Cast power", Desc = "0 = weak, 1 = maximum",
		Step  = 0.05,
		Value = { Min = 0, Max = 1, Default = Config.CastPower },
		Callback = function(v) Config.CastPower = v end,
	})
	add(sCast, "Toggle", {
		Title = "Auto equip rod", Value = Config.AutoEquip,
		Callback = function(v) Config.AutoEquip = v end,
	})

	local sHook = add(farmT, "Section", {
		Title = "Auto hook",
		Desc  = "Usually not needed - the fish bites on its own",
	})
	add(sHook, "Toggle", {
		Title = "Auto hook", Value = Config.Hook,
		Desc  = "Clicks while Searching",
		Callback = function(v) Config.Hook = v end,
	})
	add(sHook, "Slider", {
		Title = "Hook interval", Desc = "Seconds between clicks",
		Step  = 0.05,
		Value = { Min = 0.1, Max = 1.5, Default = Config.HookGap },
		Callback = function(v) Config.HookGap = v end,
	})

	local sTime = add(farmT, "Section", { Title = "Timing" })
	add(sTime, "Slider", {
		Title = "Delay between casts", Desc = "Seconds",
		Step  = 0.1,
		Value = { Min = 0.5, Max = 10, Default = Config.CastPause },
		Callback = function(v) Config.CastPause = v end,
	})
	add(sTime, "Slider", {
		Title = "Retry delay", Desc = "Seconds after a rejected cast",
		Step  = 0.1,
		Value = { Min = 0.2, Max = 5, Default = Config.CastRetry },
		Callback = function(v) Config.CastRetry = v end,
	})

	--------------------------------------------------------------------------
	--  Minigames: reel and shake
	--------------------------------------------------------------------------
	local sReel = add(farmT, "Section", {
		Title = "Reel",
		Desc  = "Keeps the slider locked on the fish",
	})
	add(sReel, "Toggle", {
		Title = "Auto reel", Value = Config.Reel,
		Callback = function(v) Config.Reel = v end,
	})
	add(sReel, "Toggle", {
		Title = "Auto lock (always PERFECT)", Value = Config.ReelAuto,
		Desc  = "The bar sticks to the fish, so the rating is never below Perfect",
		Callback = function(v) Config.ReelAuto = v end,
	})
	add(sReel, "Slider", {
		Title = "Prediction horizon", Desc = "Seconds ahead (higher = smoother)",
		Step  = 0.01,
		Value = { Min = 0.10, Max = 0.80, Default = Config.ReelHorizon },
		Callback = function(v) Config.ReelHorizon = v end,
	})
	add(sReel, "Slider", {
		Title = "Flip threshold", Desc = "Bar width fraction (lower = fewer flips)",
		Step  = 0.01,
		Value = { Min = 0.01, Max = 0.6, Default = Config.ReelFlip },
		Callback = function(v) Config.ReelFlip = v end,
	})
	add(sReel, "Toggle", {
		Title = "Reel with mouse", Value = Config.ReelMouse,
		Desc  = "Only without auto lock. Slower, needs window focus",
		Callback = function(v) Config.ReelMouse = v end,
	})

	local sShake = add(farmT, "Section", {
		Title = "Shake",
		Desc  = "LureShake mini-game",
	})
	add(sShake, "Toggle", {
		Title = "Auto shake", Value = Config.Shake,
		Desc  = "Clicks the circles automatically",
		Callback = function(v) Config.Shake = v end,
	})
	add(sShake, "Slider", {
		Title = "Click interval", Desc = "Seconds between clicks",
		Step  = 0.01,
		Value = { Min = 0.05, Max = 0.5, Default = Config.ShakeGap },
		Callback = function(v) Config.ShakeGap = v end,
	})
	add(sShake, "Toggle", {
		Title = "Click with real mouse", Value = Config.ShakeGui,
		Desc  = "Slower, needs a focused window",
		Callback = function(v) Config.ShakeGui = v end,
	})

	--------------------------------------------------------------------------
	--  Selling and bait
	--------------------------------------------------------------------------
	local sSell = add(farmT, "Section", { Title = "Selling" })
	add(sSell, "Toggle", {
		Title = "Auto sell", Value = Config.Farm,
		Callback = function(v) Config.Farm = v end,
	})
	add(sSell, "Slider", {
		Title = "Sell every", Desc = "Seconds (0 = off)",
		Step  = 5,
		Value = { Min = 0, Max = 600, Default = Config.SellEvery },
		Callback = function(v) Config.SellEvery = v end,
	})

	local sBait = add(farmT, "Section", { Title = "Bait" })
	add(sBait, "Toggle", {
		Title = "Auto bait", Value = Config.AutoBait,
		Callback = function(v) Config.AutoBait = v end,
	})
	refreshBaits()
	add(sBait, "Dropdown", {
		Title    = "Bait",
		Desc     = "Equipped by clicking the tile in the backpack",
		Value    = Config.Bait,
		Values   = S.baits,
		Callback = function(v) Config.Bait = v; S.baitAt = 0 end,
	})

	--------------------------------------------------------------------------
	--  Teleports
	--------------------------------------------------------------------------
	markHint(add(tpT, "Paragraph", {
		Title = "Locked",
		Desc  = "The access key has not been entered yet. Paste it in the first section of the Farming tab.",
	}))

	local sHome = add(tpT, "Section", {
		Title = "Home point",
		Desc  = "Where you were standing when the script started. Use it to come back from a trip",
	})
	add(sHome, "Button", {
		Title = "Go home",
		Desc  = "Teleports back to the spot the script was started on",
		Callback = function()
			local p = S.home or here()
			if not p then
				notify("Xivid Hub", "Nowhere to go back to", "Error")
				return
			end
			local char = LocalPlayer and LocalPlayer.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if not root then
				notify("Xivid Hub", "No character yet", "Error")
				return
			end
			char:PivotTo(CFrame.new(p.X, p.Y + 3, p.Z))
			root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			task.spawn(settle)
			notify("Xivid Hub", "Back at the home point", "Success")
		end,
	})
	add(sHome, "Button", {
		Title = "Set home here",
		Desc  = "Overwrites the home point with the position you are standing in right now",
		Callback = function()
			local p = here()
			if not p then
				notify("Xivid Hub", "No character yet", "Error")
				return
			end
			S.home = p
			notify("Xivid Hub", "Home point set", "Success")
		end,
	})

	add(sHome, "Toggle", {
		Title = "Surface guard", Value = Config.TpFloat,
		Desc  = "Over deep water, keeps you on the surface instead of sinking, "
			.. "so the oxygen never runs out. Turn it off if you want to dive on purpose",
		Callback = function(v) Config.TpFloat = v end,
	})

	add(tpT, "Paragraph", {
		Title = "How the travel works",
		Desc  = "The game keeps its own fast travel shut for scripts, so this tab moves the "
			.. "character directly. You are put down on ground that was measured with a ray and "
			.. "checked for being flat and for having a head above it, never on a guessed sea "
			.. "level - the sea is at y = 102 off Moosewood and at y = 153 over the Grand Reef, "
			.. "and guessing drops you under the surface. Deep places float on the surface "
			.. "above the volume. Every place you visit is remembered for next time.",
	})
	add(tpT, "Divider", {})

	local sIslands = add(tpT, "Section", {
		Title = "Islands",
		Desc  = "Sea 1 and the surrounding water. Every one of these lands on solid ground",
	})
	for _, e in ipairs(ISLANDS) do
		add(sIslands, "Button", {
			Title = e.name,
			Desc  = descFor(e),
			Callback = function()
				local ok, msg = travelTo(e.name)
				notify("Xivid Hub", ok and ("Travelling to " .. msg) or msg, ok and "Success" or "Error")
			end,
		})
	end

	local sDeep = add(tpT, "Section", {
		Title = "Deep water",
		Desc  = "These volumes sit far under the surface. Where no shore is in casting range "
			.. "you are set on top of the water and held there by the surface guard",
	})
	for _, e in ipairs(DEEP_SPOTS) do
		add(sDeep, "Button", {
			Title = e.name,
			Desc  = descFor(e),
			Callback = function()
				local ok, msg = travelTo(e.name)
				notify("Xivid Hub", ok and ("Travelling to " .. msg) or msg, ok and "Success" or "Error")
			end,
		})
	end

	add(tpT, "Paragraph", {
		Title = "Console",
		Desc  = "From the executor console:  _G.__AutoFish.Teleport(\"Roslit Bay\")",
	})

	--------------------------------------------------------------------------
	--  Theme
	--------------------------------------------------------------------------
	markHint(add(themeT, "Paragraph", {
		Title = "Locked",
		Desc  = "The access key has not been entered yet. Paste it in the first section of the Farming tab.",
	}))
	local sColors = add(themeT, "Section", {
		Title = "Colours",
		Desc  = "Neon accent of every element, glow and border",
	})
	add(sColors, "Dropdown", {
		Title    = "Accent colour",
		Desc     = "Border, sliders, switches, text glow",
		Value    = Config.Accent,
		Values   = ACCENT_ORDER,
		Callback = function(v) Config.Accent = v; applyStyle() end,
	})
	add(sColors, "Toggle", {
		Title = "Neon glow", Value = Config.Glow,
		Desc  = "Coloured outline around every piece of text",
		Callback = function(v) Config.Glow = v; applyStyle() end,
	})
	add(sColors, "Slider", {
		Title = "Glow strength", Desc = "0 = flat, 1 = full neon",
		Step  = 0.05,
		Value = { Min = 0, Max = 1, Default = Config.GlowLevel },
		Callback = function(v) Config.GlowLevel = v; applyStyle() end,
	})

	local sFont = add(themeT, "Section", {
		Title = "Font",
		Desc  = "Used for every label in the interface",
	})
	add(sFont, "Dropdown", {
		Title    = "Font",
		Value    = Config.Font,
		Values   = FONTS,
		Callback = function(v) Config.Font = v; applyStyle() end,
	})
	add(sFont, "Toggle", {
		Title = "Press animation", Value = Config.Anim,
		Desc  = "Short neon flash and a small squeeze on click",
		Callback = function(v) Config.Anim = v end,
	})

	local sAudio = add(themeT, "Section", { Title = "Audio" })
	add(sAudio, "Toggle", {
		Title = "Interface sounds", Value = Config.Sound,
		Desc  = "A click on every switch, button and slider",
		Callback = function(v) Config.Sound = v end,
	})
	add(sAudio, "Slider", {
		Title = "Volume", Desc = "0 = silent",
		Step  = 0.05,
		Value = { Min = 0, Max = 1, Default = Config.Volume },
		Callback = function(v) Config.Volume = v; sfx("Tick") end,
	})

	--------------------------------------------------------------------------
	--  Settings
	--------------------------------------------------------------------------
	markHint(add(optT, "Paragraph", {
		Title = "Locked",
		Desc  = "The access key has not been entered yet. Paste it in the first section of the Farming tab.",
	}))
	local sCfg = add(optT, "Section", { Title = "Config" })
	add(sCfg, "Button", {
		Title = "Save settings",
		Callback = function()
			saveConfig()
			notify("Xivid Hub", "Settings saved", "Success")
		end,
	})
	add(sCfg, "Button", {
		Title = "Load settings",
		Callback = function()
			loadConfig()
			applyStyle()
			notify("Xivid Hub", "Settings loaded")
		end,
	})
	add(sCfg, "Button", {
		Title = "Reset to defaults",
		Callback = function()
			resetConfig()
			applyStyle()
			notify("Xivid Hub", "Defaults restored")
		end,
	})
	add(sCfg, "Toggle", {
		Title = "Verbose log", Value = Config.Debug,
		Desc  = "Prints the bot internals to the console",
		Callback = function(v) Config.Debug = v end,
	})

	add(optT, "Paragraph", { Title = "Hotkeys" })
	add(optT, "Divider", {})
	add(optT, "Paragraph", {
		Title = "Keys",
		Desc  = "F5 - on / off\nF6 - auto reel\nF7 - auto shake\nF8 - auto cast\nF9 - auto lock",
	})
	add(optT, "Paragraph", {
		Title = "Console",
		Desc  = "_G.__AutoFish.Enable()\n_G.__AutoFish.Disable()\n_G.__AutoFish.Toggle()\n_G.__AutoFish.Dump()",
	})

	-- WindUI's own config folder is not used: every option (accent, font,
	-- sound, timings) lives in the settings file above, so the two systems
	-- can never fight over the same values.
	applyFontEverywhere(true)

	--------------------------------------------------------------------------
	--  Live text (4 times per second)
	--------------------------------------------------------------------------
	--  Paragraph in this WindUI version has no Text field - the text is
	--  changed through SetDesc, so we use that (with a fallback).
	local function setText(widget, text)
		if not widget then return end
		if type(widget.SetDesc) == "function" then
			pcall(widget.SetDesc, widget, text)
		else
			pcall(function() widget.Text = text end)
		end
	end

	local function setProgress(pct)
		if not barReel then return end
		pct = math.clamp(tonumber(pct) or 0, 0, 100)
		local ui = barReel.UIElements
		if not ui then return end
		if ui.Fill and ui.Fill:IsA("GuiObject") then
			ui.Fill.Size = UDim2.new(pct / 100, 0, 1, 0)
		end
		if ui.Value and ui.Value:IsA("TextLabel") then
			ui.Value.Text = ("%d%%"):format(math.floor(pct))
		end
	end

	local lastPaint = 0
	local lastFont = 0
	local lastCaught = -1
	keep(RunService.Heartbeat:Connect(function()
		local t = now()
		if t - lastPaint < 0.25 then return end
		lastPaint = t

		-- WindUI creates some labels late, so the font/glow pass keeps running
		if t - lastFont > 2 then
			lastFont = t
			applyFontEverywhere(false)
		end

		setText(lblState, ("Rod: %s\n%s"):format(
			S.status,
			S.note ~= "" and S.note or "-"
		))

		if S.reelSeen > 0 then
			local mark = S.reelPerfect and "PERFECT" or "normal"
			local mode = S.reelAssist and "auto lock" or "predictive"
			setText(lblReel, ("Progress: %d%%  [%s]\n%s  |  %s"):format(
				math.floor(S.reelProg or 0),
				mark, mode,
				S.fishName ~= "" and S.fishName or "-"
			))
			setProgress(S.reelProg)
		else
			setText(lblReel, "Reel is idle")
			setProgress(0)
		end

		setText(lblCast, "Cast: remote (works minimized)")

		local cur = currentBait()
		local caught = caughtCount()
		setText(lblFarm, ("Caught this session: %d\nBait: %s"):format(
			caught,
			Config.Bait == BAIT_KEEP and (cur and cur.Value or "-") or Config.Bait
		))

		if lastCaught >= 0 and caught > lastCaught then
			sfx("Splash", 0.7)
		end
		lastCaught = caught
	end))

	-- remember the untouched colour of the key field so a wrong key can flash
	-- red and then fall back to the accent on its own
	pcall(function()
		local fr = keyInput and (keyInput.InputFrame or keyInput.ElementFrame)
		if fr then keyBg = fr.BackgroundColor3 end
	end)

	-- the menu is locked until the key is accepted. If the console handed the
	-- key over while the window was still building, it is already unlocked and
	-- the gate has to be taken down instead of being put up.
	setLocked(not S.unlocked)

	-- a key handed over by the console while the window was still building
	if keyPending then
		local k = keyPending
		keyPending = nil
		pcall(function()
			for _, d in ipairs(keyInput.ElementFrame:GetDescendants()) do
				if d:IsA("TextBox") then d.Text = k break end
			end
		end)
		tryUnlock(k)
	end

	if #errors > 0 then
		warn("[AutoFish] UI: " .. table.concat(errors, " | "))
	end
	-- show the window right away so the menu is never lost
	pcall(function()
		if type(window.Toggle) == "function" and window.Hidden then
			window:Toggle()
		end
		if type(window.Open) == "function" and not window.Closed then
			window:Open()
		end
	end)
	_G.__AutoFishErrors = errors
	logf("interface ready, widget errors: %d", #errors)
end

--------------------------------------------------------------------------------
--  HOTKEYS
--------------------------------------------------------------------------------

local function bindKeys()
	local map = {
		[Enum.KeyCode.F5] = function()
			if not S.unlocked then
				notify("Xivid Hub", "Enter the access key first", "Error")
				sfx("Off")
				return
			end
			Config.Enabled = not Config.Enabled
			S.caught0 = nil
			setStatus(Config.Enabled and "Enabled" or "Disabled")
			notify("Xivid Hub", Config.Enabled and "Enabled" or "Disabled",
				Config.Enabled and "Success" or nil)
			sfx(Config.Enabled and "Done" or "Off")
		end,
		[Enum.KeyCode.F6] = function() Config.Reel     = not Config.Reel     sfx("Switch") end,
		[Enum.KeyCode.F7] = function() Config.Shake    = not Config.Shake    sfx("Switch") end,
		[Enum.KeyCode.F8] = function() Config.Cast     = not Config.Cast     sfx("Switch") end,
		[Enum.KeyCode.F9] = function() Config.ReelAuto = not Config.ReelAuto sfx("Switch") end,
	}

	keep(UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		local fn = map[input.KeyCode]
		if fn then fn() end
	end))
end

--------------------------------------------------------------------------------
--  START
--------------------------------------------------------------------------------

local started = false

local function start()
	if started then return end
	started = true

	-- the invite is on the clipboard before anything else happens, so it is
	-- already there even if the game is still loading
	copyInvite(true)

	dropAll() -- just in case the script is started twice

	if not waitReady() then
		warn("[Xivid Hub] the game did not load - the script stopped")
		return
	end

	loadConfig()
	loadSpots()
	sanitizeStyle()
	-- the "Go home" button needs a starting point to come back to
	S.home = here()
	S.floatTop = 0
	assistHook()
	-- if a reel is already running, install auto lock right away
	pcall(assistInstall, ReelController.ActiveReel)
	bindKeys()
	keep(RunService.Heartbeat:Connect(tick))
	task.spawn(floatLoop)
	-- the menu is built separately: assembling WindUI takes a couple of
	-- seconds and the clipboard has to be filled immediately
	task.spawn(buildUI)

	-- F5 / the console cannot switch the bot on before the key is accepted
	local function requireKey()
		if S.unlocked then return true end
		notify("Xivid Hub", "Enter the access key first", "Error")
		sfx("Off")
		return false
	end

	_G.__AutoFish = {
		Config = Config,
		State  = S,
		Enable  = function() if requireKey() then Config.Enabled = true;  setStatus("Enabled");  sfx("Done") end end,
		Disable = function() Config.Enabled = false; setStatus("Disabled"); sfx("Off") end,
		Toggle  = function()
			if not requireKey() then return end
			Config.Enabled = not Config.Enabled
			setStatus(Config.Enabled and "Enabled" or "Disabled")
			sfx(Config.Enabled and "Done" or "Off")
		end,
		-- key gate
		Discord  = DISCORD_LINK,
		Unlocked = function() return S.unlocked end,
		Unlock   = function(typed)
			-- the menu fills the field itself; the argument is for the console
			if type(typed) == "string" then
				keyPending = typed
				if keyInput and keyInput.ElementFrame then
					pcall(function()
						for _, d in ipairs(keyInput.ElementFrame:GetDescendants()) do
							if d:IsA("TextBox") then d.Text = typed break end
						end
					end)
				end
			end
			tryUnlock(typed)
		end,
		Invite   = function() return copyInvite(false) end,
		-- island travel
		Teleport = function(name)
			if not S.unlocked then
				notify("Xivid Hub", "Enter the access key first", "Error")
				return false
			end
			local ok, msg = travelTo(name)
			notify("Xivid Hub", ok and ("Travelling to " .. msg) or msg, ok and "Success" or "Error")
			return ok
		end,
		Spots    = function()
			local out, seen = {}, {}
			for name in pairs(SPOT_BY_NAME) do
				seen[name] = true
				out[#out + 1] = name
			end
			for name in pairs(learned) do
				if not seen[name] then out[#out + 1] = name end
			end
			table.sort(out)
			return table.concat(out, ", ")
		end,
		Save    = saveConfig,
		Load    = loadConfig,
		Reset   = resetConfig,
		Theme   = applyStyle,
		Style   = applyStyle, -- old name, kept so old scripts keep working
		Sound   = function(name) sfx(name or "Click") end,
		Stop    = function()
			Config.Enabled = false
			dropAll()
			assistRemove()
			pcall(killOldUI)
			started = false
			print("[Xivid Hub] stopped")
		end,
		Dump    = function()
			return ("key=%s  state=%s  note=%s  reel=%.0f%% perfect=%s  caught=%d"):format(
				S.unlocked and "ok" or "locked",
				S.status, S.note, S.reelProg or 0,
				tostring(S.reelPerfect), caughtCount())
		end,
	}

	print("[Xivid Hub] loaded. The invite is on your clipboard - join the Discord server and paste the key into the window.")
	logf("start: window focused = %s", tostring(windowFocused()))
end

task.spawn(start)

return _G.__AutoFish
