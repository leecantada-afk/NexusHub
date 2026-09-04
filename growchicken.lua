--[[ ============================================================
     NEXUS HUB — Grow a Chicken Fighter
     Organized: helpers -> loops (by category) -> UI build
     ============================================================ ]]

-- Per-generation token: every load bumps it, and each loop captures
-- its own gen at spawn. An old instance's loops die the instant a
-- newer one loads, because they gate on gen == getgenv().NEXUS_GEN.
-- This prevents stale loop threads from a destroyed window from
-- keeping a toggle "on" (e.g. auto-upgrading the coop) after reload.
getgenv().NEXUS_GEN = (getgenv().NEXUS_GEN or 0) + 1
local gen = getgenv().NEXUS_GEN

------------------------------------------------------------------
-- Services & requires
------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Player = Players.LocalPlayer
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:FindFirstChild("Packages") or ReplicatedStorage:WaitForChild("Packages")
local client = require(Packages.DataService).client
local Remotes = require(ReplicatedStorage.Core.Remotes)
local GameConfig = require(ReplicatedStorage.Content.GameConfig)
local MissionView = require(ReplicatedStorage.Features.Missions.MissionView)
local CoopView = require(ReplicatedStorage.Features.Coop.CoopView)
local RecyclerView = require(ReplicatedStorage.Features.Scrap.RecyclerView)
local IncubatorView = require(ReplicatedStorage.Features.Incubator.IncubatorView)
local FusionRules = require(ReplicatedStorage.Features.Chicken.FusionRules)
local ChickenMode = require(Player.PlayerScripts.Features.Chicken.ChickenMode)
local RebirthBonus = require(ReplicatedStorage.Core.Progression.RebirthBonus)
local RebirthExperiment = require(ReplicatedStorage.Core.Progression.RebirthExperiment)
local Ladder = require(ReplicatedStorage.Features.Battle.campaign.Ladder)

-- Rayfield is shared globally so re-runs don't stack windows
local Rayfield = getgenv().NexusRayfield
if not Rayfield then
    Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()
    getgenv().NexusRayfield = Rayfield
end

local inv = Remotes.invoke
local R = Remotes.defs
local GC = GameConfig.generators

-- True for the CURRENT instance only; stale instances fail this.
local function hubAlive()
    return getgenv().NX_HUB == true and gen == getgenv().NEXUS_GEN
end

------------------------------------------------------------------
-- Window de-dup guard.
-- Every execution must result in exactly ONE hub window. Rejoins run the
-- script through plain loadstring (queue_on_teleport / autoload), where
-- Real's STATE/live-reload teardown is NOT available, so each rejoin used to
-- stack a fresh Rayfield window on top of every previous one. Fix: before we
-- ever build a window, sweep CoreGui and hard-destroy EVERY existing "NEXUS
-- HUB" window (and Rayfield's notification shell). This runs no matter how
-- the script was launched, so old windows can never survive a new execution.
local function killAllNexusWindows()
    for _, sg in ipairs(game:GetService("CoreGui"):GetDescendants()) do
        if sg:IsA("ScreenGui") or sg:IsA("LayerCollector") then
            pcall(function()
                if sg:FindFirstChild("NEXUS HUB") or sg.Name == "Notifications" then
                    sg:Destroy()
                end
            end)
        end
    end
end

-- Registry so an in-session re-run can also tear down the current window the
-- moment a newer instance takes over.
getgenv().NexusHubWin = nil

------------------------------------------------------------------
-- Config
------------------------------------------------------------------
local flags = {
    upgradeFeeder = false,
    buyFeeder = false,
    sendTower = false,
    rebirthFarm = false, -- one toggle = auto tower + 2-farm upgrade + retreat-rebirth
    -- tower strategy: "frontier" | "warmup" | "bottom"
    towerStrategy = "frontier",
    upgradeCoop = false,
    upgradeRecycler = false,
    autoClaimEggIncubator = false,
    autoUpgradeIncubator = false,
    autoCollectEggs = false,   -- walk to world egg drops (NestEggs) to collect them
    collectEggRadius = 200,    -- max scan distance (studs) for world egg drops
    autoFuse = false,
    autoSell = false,
    autoArena = false,
    chaos = false,        -- Auto Chaos: send to the Center Ring once health is full
    claimMissions = false,
    claimDaily = false,
    claimRebirth = false,
    autoPet = false,
    autoClaimPass = false,
    autoShopDust = false,
    antiAfk = false,
    performance = false,
    ultraPerformance = false,
    autoLoadOnTeleport = false,
    autoReconnect = false,
}

------------------------------------------------------------------
-- Shared helpers
------------------------------------------------------------------
local function money()
    local ok, m = pcall(function() return client:get({"money"}) end)
    if ok and type(m) == "number" then return m end
    return 0
end

local function coop()
    local ok, c = pcall(function() return client:get({"coop"}) end)
    if ok and c then return c end
    return { generators = {}, slots = 0 }
end

local function roster()
    local ok, r = pcall(function() return client:get({"roster"}) end)
    if ok and r then return r end
    return { eggs = {}, activeId = nil }
end

local function vitals()
    local ok, v = pcall(function() return client:get({"vitals"}) end)
    if ok and v then return v end
    return { health = 1 }
end

local function towerBest()
    local ok, t = pcall(function() return client:get({"tower"}) end)
    if ok and t and t.best then return t.best end
    return 0
end

local function incubatorData()
    local ok, d = pcall(function() return client:get({"incubator"}) end)
    if ok and d then return d end
    return { eggs = {}, level = 0, progress = 0 }
end

local function rebirthCount()
    local ok, rb = pcall(function() return client:get({"rebirth"}) end)
    return (ok and type(rb) == "table" and rb.count) or 0
end

-- flat list of owned chickens (excluding eggs), with ids
local function chickenList()
    local r = roster()
    local out = {}
    if type(r.chickens) == "table" then
        for _, c in ipairs(r.chickens) do
            if c and c.id then table.insert(out, c) end
        end
    end
    return out
end

local function pcallInvoke(...)
    local ok, err = pcall(inv, ...)
    return ok, err
end

local function getCharRoot()
    local c = Player.Character
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart")
end

-- True only when the rooster is resting at the corral, mirroring the
-- server's gate for rebirth (it rejects with "busyTower"/"notAtCoop").
local function atCorral()
    return ChickenMode.order() == "coop" and ChickenMode.where() == "corral"
end

-- True when the tower best has already met this player's rebirth
-- requirement floor. Rebirth also needs the chicken AT the corral, so
-- while this is true we hold the chicken home instead of re-sending it
-- to the tower, letting it rest at the corral for the rebirth to fire.
local function rebirthReady()
    local ok, count = pcall(function() return rebirthCount() end)
    local arm = (pcall(function() return RebirthExperiment.armOf(Player) end)
        and RebirthExperiment.armOf(Player)) or "control"
    local floor = RebirthBonus.requirementFloorFor(count or 0, arm == RebirthExperiment.VARIANT)
    return towerBest() >= floor
end

------------------------------------------------------------------
-- SERVER hops
------------------------------------------------------------------

-- Fetch the public server list for this place via the Roblox games API.
-- Returns an array of { id=jobId, playing=players, max=maxPlayers, ping }.
local function fetchServers()
    local list = {}
    local ok, res = pcall(function()
        return request({
            Url = "https://games.roblox.com/v1/games/" .. game.PlaceId
                .. "/servers/Public?limit=100&sortOrder=Desc",
            Method = "GET",
        })
    end)
    if not ok or type(res) ~= "table" or type(res.Body) ~= "string" then
        return list
    end
    local ok2, data = pcall(function()
        return game:GetService("HttpService"):JSONDecode(res.Body)
    end)
    if not ok2 or type(data) ~= "table" then return list end
    for _, s in ipairs(data.data or {}) do
        if type(s) == "table" and type(s.id) == "string" then
            table.insert(list, {
                id = s.id,
                playing = tonumber(s.playing) or 0,
                max = tonumber(s.maxPlayers) or 0,
                ping = tonumber(s.ping) or 0,
            })
        end
    end
    return list
end

-- Queue the hub to re-load itself in the new server when Auto Load on
-- Teleport is enabled. Reads the canonical source from the workspace copy.
local function queueHubReload()
    if not flags.autoLoadOnTeleport then return end
    local ok, src = pcall(readfile, "nexus_hub_reload.luau")
    if ok and type(src) == "string" then
        pcall(queue_on_teleport, "loadstring(readfile('nexus_hub_reload.luau'))()")
    end
end

-- Keep-alive: while the hub is alive and Auto Load on Teleport is on, re-queue
-- our reload on a timer. queue_on_teleport holds only ONE source (last writer
-- wins), and other hubs (e.g. Apel) overwrite it. Re-queuing every few seconds
-- makes sure the Nexus hub is the one that runs after a teleport/rejoin.
-- Cheap: just a readfile + set of a string.
-- A generation token keeps only ONE keep-alive alive: each call bumps the
-- token, so any prior loop (still sleeping in task.wait) dies on its next
-- iteration instead of stacking a second, redundant re-queuer.
local queueKeepAliveGen = 0
local function runQueueKeepAlive()
    if not flags.autoLoadOnTeleport then return end
    local myGen = queueKeepAliveGen + 1
    queueKeepAliveGen = myGen
    task.spawn(function()
        while hubAlive() and flags.autoLoadOnTeleport and queueKeepAliveGen == myGen do
            queueHubReload()
            task.wait(4)
        end
    end)
end

-- Teleport to a specific server (jobId). Same-place hop within this game.
local function hopToJob(jobId)
    if not jobId or jobId == "" then return false end
    queueHubReload()
    local TeleportService = game:GetService("TeleportService")
    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId)
    end)
    return ok, err
end

-- Server Hop: teleport to a random server that is not this one.
local function serverHop()
    local servers = fetchServers()
    local others = {}
    for _, s in ipairs(servers) do
        if s.id ~= game.JobId then table.insert(others, s.id) end
    end
    if #others == 0 then return false, "no other servers found" end
    local job = others[math.random(1, #others)]
    return hopToJob(job)
end

-- Server Hop Low Players: teleport to the server with the fewest players.
local function serverHopLow()
    local servers = fetchServers()
    local best
    for _, s in ipairs(servers) do
        if s.id ~= game.JobId then
            if not best or s.playing < best.playing then
                best = s
            end
        end
    end
    if not best then return false, "no other servers found" end
    return hopToJob(best.id)
end

-- Rejoin: teleport back into the very same server you are on.
local function rejoin()
    return hopToJob(game.JobId)
end

-- Auto Reconnect: when enabled, if we get kicked or removed from the server,
-- teleport straight back into the same server (Auto Load on Teleport reloads
-- the hub on arrival). Watches LocalPlayer's Parent — a kick sets it to nil.
local function runAutoReconnect()
    local reconnectToken = { armed = false }
    local function tryReconnect()
        if not (hubAlive() and flags.autoReconnect) then return end
        if reconnectToken.armed then return end -- only one reconnect per removal
        reconnectToken.armed = true
        task.spawn(function()
            task.wait(0.8) -- let the kick / server state settle before bouncing back
            if hubAlive() and flags.autoReconnect then
                queueHubReload()
                pcall(function()
                    game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, game.JobId)
                end)
            end
            reconnectToken.armed = false
        end)
    end
    local changedConn = Player:GetPropertyChangedSignal("Parent"):Connect(tryReconnect)
    local removingConn = game:GetService("Players").PlayerRemoving:Connect(function(p)
        if p == Player then tryReconnect() end
    end)
    while hubAlive() and flags.autoReconnect do
        task.wait(5)
    end
    pcall(function() changedConn:Disconnect() end)
    pcall(function() removingConn:Disconnect() end)
end

------------------------------------------------------------------
-- FARM loops
------------------------------------------------------------------

-- The four Farm actions that spend money on the coop (upgrade feeder, buy
-- feeder, upgrade coop) all read the same cached coop()/money() data and fire
-- coop remotes. If two of them act in the same instant they race on stale
-- state and double-spend, which is what made "Auto Upgrade Feeder" look like
-- it also triggered the coop upgrade. A single shared lock lets only one of
-- them fire at a time, so they can never interfere.
local farmLocked = false
local function withFarmLock(fn)
    if farmLocked then return end
    farmLocked = true
    pcall(fn)
    farmLocked = false
end

-- Loop registry: toggling a feature off then on used to spawn a SECOND copy of
-- the same loop (both kept running because they both saw flags.X == true).
-- Running only the registered copy prevents stale duplicate loops from acting
-- after a re-toggle.
local runningLoops = {}
local function spawnLoop(flagKey, fn)
    if runningLoops[flagKey] then return end
    runningLoops[flagKey] = true
    task.spawn(function()
        pcall(fn)
        runningLoops[flagKey] = false
    end)
end

-- Auto Upgrade Feeder: raise every generator toward maxLevel, cheapest first
local function runUpgradeFeeder()
    while hubAlive() and flags.upgradeFeeder do
        local c = coop()
        local gens = c.generators or {}
        local bestSlot, bestCost = nil, nil
        for _, g in ipairs(gens) do
            if g.level and g.level < GC.maxLevel then
                local cost = math.floor(GC.upgradeCost.base * (GC.upgradeCost.growth ^ math.max(0, g.level - 1)))
                if bestSlot == nil or cost < bestCost then
                    bestCost, bestSlot = cost, g.slot
                end
            end
        end
        if bestSlot and money() >= (bestCost or 0) then
            withFarmLock(function() pcallInvoke(R.UpgradeGenerator, bestSlot) end)
        end
        task.wait(0.25)
    end
end

-- Auto Buy Feeder: fill slots, expanding the coop when a new slot is needed
local function runBuyFeeder()
    while hubAlive() and flags.buyFeeder do
        local c = coop()
        local gens = c.generators or {}
        local slots = c.slots or #gens
        local cur = #gens -- each generator owns a slot; next index is first empty
        if cur < GC.maxSlots and cur >= slots then
            -- need to expand the coop to open another slot
            local cost = math.floor(GC.expandCost.base * (GC.expandCost.growth ^ math.max(0, cur - GC.coopMinSize)))
            if money() >= cost then
                withFarmLock(function() pcallInvoke(R.ExpandCoop) end)
                task.wait(1.5)
            end
        elseif cur < GC.maxSlots and cur < slots then
            local cost = math.floor(GC.buyCost.base * (GC.buyCost.growth ^ math.max(0, cur - 1)))
            if money() >= cost then
                withFarmLock(function() pcallInvoke(R.BuyGenerator, cur + 1) end)
                task.wait(1.5)
            end
        end
        task.wait(1.0)
    end
end

-- Tower start-floor helper. The three Auto Farm tower strategies pick which
-- floor the run begins at:
--   "bottom"   -> start from floor 1 (full fresh run)
--   "frontier" -> start at your current best (frontier)
--   "warmup"   -> start a few floors below the frontier to build up power
local TOWER_WARMUP_OFFSET = 5
local function towerStartFloor()
    local front = Ladder.frontier(towerBest())
    local s = flags.towerStrategy or "frontier"
    if s == "bottom" then
        return 1
    elseif s == "warmup" then
        return math.max(1, front - TOWER_WARMUP_OFFSET)
    else
        return front
    end
end

-- Auto Send Tower: send when idle (full health) — but not while a hot egg
-- is live, and not when the rebirth requirement is already met (we hold the
-- chicken at the corral so the rebirth loop can fire it). Starts the run at
-- the floor chosen by the tower strategy, and always declines the "continue"
-- offer so a failed run ends instead of paying to keep going.
local continueConn = nil
local function runSendTower()
    -- decline the tower continue offer whenever auto-farm is on
    if not continueConn then
        continueConn = Remotes.onClient(R.TowerContinueOffer, function()
            task.spawn(function() pcall(Remotes.fire, R.TowerContinueDecline) end)
        end)
    end
    while hubAlive() and flags.sendTower do
        local v = vitals()
        if (v.health or 1) >= 0.999 and not (flags.rebirthFarm and rebirthReady()) then
            task.spawn(function() pcallInvoke(R.TowerStart, towerStartFloor()) end)
            task.wait(2.5)
        end
        task.wait(0.7)
    end
    if continueConn then
        pcall(function() continueConn:Disconnect() end)
        continueConn = nil
    end
end

-- Rebirth Farm (beta). ONE toggle drives the whole rebirth grind loop:
--   * Auto farm tower   -> send the rooster to the strategy floor, refarm
--   * Keep 2 feeders    -> buy feeders until there are exactly TWO (never a
--                          third), then upgrade only those two; NEVER expands
--                          or upgrades the coop
--   * Retreat / rebirth -> once the rebirth threshold is met, surrender any
--                          running tower, return to the corral and fire rebirth
-- It shares the tower continue-decline connection so failed full runs settle
-- instead of paying to keep going. Everything gates on the single flag.
-- Auto-click the tower-end "No thanks" button: when the server shows the
-- tower continue offer (the tower run ended), decline it. This fires the same
-- TowerContinueDecline remote the game's own "No thanks" button sends, so it
-- is refused without paying to continue the run.
local rfContinueConn = nil
local function runRebirthFarm()
    if not rfContinueConn then
        rfContinueConn = Remotes.onClient(R.TowerContinueOffer, function()
            task.spawn(function() pcall(Remotes.fire, R.TowerContinueDecline) end)
        end)
    end
    -- Feeder loop: continuous, gated only on the flag. Buys up to 2 feeders
    -- (never a 3rd, never expands), then raises both to max as fast as the
    -- server round trip allows. Not throttled by the tower/rebirth pacing.
    task.spawn(function()
        while hubAlive() and flags.rebirthFarm do
            local c = coop()
            local gens = c.generators or {}
            local slots = c.slots or #gens
            local cur = #gens
            if cur < 2 and cur < slots then
                local cost = math.floor(GC.buyCost.base * (GC.buyCost.growth ^ math.max(0, cur - 1)))
                if money() >= cost then
                    withFarmLock(function() pcallInvoke(R.BuyGenerator, cur + 1) end)
                    task.wait(0.15)
                end
            end
            local c2 = coop()
            local gens2 = c2.generators or {}
            local bestSlot, bestCost = nil, nil
            for i = 1, math.min(2, #gens2) do
                local g = gens2[i]
                if g and g.level and g.level < GC.maxLevel then
                    local cost = math.floor(GC.upgradeCost.base * (GC.upgradeCost.growth ^ math.max(0, g.level - 1)))
                    if bestSlot == nil or cost < bestCost then
                        bestCost, bestSlot = cost, g.slot
                    end
                end
            end
            if bestSlot and money() >= (bestCost or 0) then
                withFarmLock(function() pcallInvoke(R.UpgradeGenerator, bestSlot) end)
            end
            task.wait(0.12)
        end
    end)
    -- Tower + rebirth loop: slower paced, independent of the feeder loop.
    -- Fires rebirth the instant the chicken retreats to the corral (the server
    -- only requires being home + meeting the floor: no full-health wait).
    while hubAlive() and flags.rebirthFarm do
        if rebirthReady() and not atCorral() then
            pcallInvoke(R.TowerSurrender)
            task.wait(1.0)
        end
        if rebirthReady() and atCorral() then
            pcallInvoke(R.Rebirth)
            task.wait(3)
        end
        if not rebirthReady() and (vitals().health or 1) >= 0.999 then
            task.spawn(function() pcallInvoke(R.TowerStart, towerStartFloor()) end)
        end
        task.wait(0.6)
    end
    if rfContinueConn then
        pcall(function() rfContinueConn:Disconnect() end)
        rfContinueConn = nil
    end
end

------------------------------------------------------------------
-- PROGRESSION loops
------------------------------------------------------------------

-- Auto Upgrade Coop: expand capacity/slots toward maxSlots when affordable
local function runUpgradeCoop()
    while hubAlive() and flags.upgradeCoop do
        local slots = coop().slots or 0
        if slots < GC.maxSlots and CoopView.canExpand(slots) then
            local cost = CoopView.expandCost(slots) or 0
            if money() >= cost then
                withFarmLock(function() pcallInvoke(R.ExpandCoop) end)
                task.wait(0.4)
            end
        end
        task.wait(0.25)
    end
end

-- Auto Upgrade Recycler: raise the recycler while affordable and unlocked
local function runUpgradeRecycler()
    while hubAlive() and flags.upgradeRecycler do
        local ok, scrap = pcall(function() return client:get({"scrap"}) end)
        local level = (ok and scrap and scrap.recyclerLevel) or 0
        local rbCount = rebirthCount()
        local best = towerBest()
        if RecyclerView.canUpgrade(level, rbCount)
            and RecyclerView.floorUnlocked(level, best)
            and money() >= (RecyclerView.upgradeCost(level) or 0) then
            pcallInvoke(R.UpgradeRecycler)
            task.wait(0.4)
        end
        task.wait(0.25)
    end
end

-- Auto Claim Egg Incubator: claim ready incubated eggs only (no tenant/upgrade)
local function runAutoClaimEggIncubator()
    while hubAlive() and flags.autoClaimEggIncubator do
        if #(incubatorData().eggs or {}) > 0 then
            pcallInvoke(R.IncubatorClaim)
            task.wait(1.0)
        end
        task.wait(5.0)
    end
end

-- Auto Collect Nest Eggs: collect the player's world egg drops under
-- Workspace.NestEggs by gliding the character onto each egg so the server
-- (proximity/touch based) picks it up. Eggs are server-owned and anchored, so
-- there is no "pull the egg to me" magnet and no collect remote — the character
-- must physically reach the egg's server position. To avoid the movement guard
-- (flags any frame moving >8 studs, 3 strikes = disconnect), we GLIDE: step the
-- root toward the egg in small Heartbeat increments, always well under the cap,
-- so it snaps to each egg near-instantly without a visible walk and without a
-- kick. Continuously rescans so eggs that drop after the chicken's lay-countdown
-- are caught as soon as they appear.
local scanEggGap = 0.5   -- seconds between egg scans
local SAFE_GLIDE = 18    -- studs/s sustained glide speed (under the 24/s speed cap)

local function scanNestEggs(radius)
    local out = {}
    local NestEggs = Workspace:FindFirstChild("NestEggs")
    local hrp = getCharRoot()
    if not NestEggs or not hrp then return out end
    local uid = Player and Player.UserId
    for _, v in ipairs(NestEggs:GetChildren()) do
        if v:IsA("BasePart") and v.Parent then
            local owner = v:GetAttribute("owner")
            if (owner == nil or owner == uid) and (v.Position - hrp.Position).Magnitude <= radius then
                table.insert(out, v)
            end
        end
    end
    return out
end

-- Glide the root part to a target at a safe sustained speed. The movement guard
-- flags (a) any frame moving >8 studs and (b) sustained speed above ~24 studs/s;
-- both mean a fast "snap" or a long jump trips it and kicks. So we move the root
-- by SAFE_GLIDE * dt each Heartbeat frame: ~18 studs/s. That is comfortably under
-- BOTH the per-frame teleport cap and the sustained speed cap, so the collector
-- visibly darts to each egg without ever triggering a strike.
local function glideTo(target, reach)
    local hrp = getCharRoot()
    local hum = Player.Character and Player.Character:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then return false end
    -- cancel any MoveTo the player is doing so the root isn't fought
    pcall(function() hum:MoveTo(hrp.Position) end)
    if (target - hrp.Position).Magnitude <= reach then return true end
    local budget = 20
    while hubAlive() and budget > 0 do
        local root = getCharRoot()
        if not root then return false end
        local toGo = target - root.Position
        local dist = toGo.Magnitude
        if dist <= reach then
            root.CFrame = CFrame.new(target)
            return true
        end
        local dt = RunService.Heartbeat:Wait()
        budget = budget - dt
        root.CFrame = root.CFrame + toGo.Unit * (SAFE_GLIDE * dt)
    end
    return false
end

-- Locate the local player's own chicken body in the world. With Auto Pet on
-- the chicken stays *still* in corral state, so its position is a stable egg
-- spawn point; we return its part so we can anchor the character on it.
local function myChickenBody()
    local cb = Workspace:FindFirstChild("ChickenBodies")
    if not cb then return nil end
    local uid = Player and Player.UserId
    for _, c in ipairs(cb:GetChildren()) do
        if c:IsA("BasePart") and c:GetAttribute("ovOwner") == uid then
            return c
        end
    end
    return nil
end

-- Glue the character beside the player's own chicken so every egg is caught the
-- instant it drops. The server collects when the player is within ~7 studs
-- horizontally of the egg, so we keep the root horizontally aligned with the
-- chicken (leaving Y to gravity) and re-anchor the moment it relocates (Auto
-- Pet makes it hold still most of the time, but the server can walk/teleport it
-- around the coop, so we follow). Falls back to scanning the world for owned
-- eggs if no chicken body is tracked.
local function runAutoCollectEggs()
    while hubAlive() and flags.autoCollectEggs do
        local chick = myChickenBody()
        if chick and chick.Parent then
            -- Stand beside the chicken (within the ~7-stud horizontal radius).
            -- We only correct the horizontal plane and leave Y to gravity, so
            -- the character doesn't bounce up and down trying to hover.
            local hrp = getCharRoot()
            if hrp then
                local soglia = Vector3.new(chick.Position.X, hrp.Position.Y, chick.Position.Z)
                local flat = Vector3.new(soglia.X - hrp.Position.X, 0, soglia.Z - hrp.Position.Z)
                -- Re-anchor once we drift off the egg spawn point; the glide
                -- keeps the character's Y so it stays grounded.
                if flat.Magnitude > 2.5 then
                    glideTo(soglia, 1.0)
                end
            end
        else
            -- No tracked chicken: fall back to scanning the world for owned eggs.
            local hrp = getCharRoot()
            if hrp then
                local list = scanNestEggs(flags.collectEggRadius)
                for _, egg in ipairs(list) do
                    if not hubAlive() then break end
                    if not egg.Parent then continue end
                    glideTo(egg.Position, 2)
                    task.wait(0.3)
                end
            end
        end
        task.wait(scanEggGap)
    end
end

-- Auto Upgrade Incubator: raise the incubator level (no claim / tenant)
local function runAutoUpgradeIncubator()
    while hubAlive() and flags.autoUpgradeIncubator do
        local lvl = incubatorData().level or 0
        if IncubatorView.canUpgrade(lvl, rebirthCount()) and lvl < IncubatorView.maxLevel then
            local cost = IncubatorView.upgradeCost(lvl + 1) or 0
            if money() >= cost then
                pcallInvoke(R.IncubatorUpgrade)
                task.wait(0.4)
            end
        end
        task.wait(0.25)
    end
end

-- Auto Fuse Chickens: fuse two of the same typeId into a stronger one
local function runAutoFuse()
    while hubAlive() and flags.autoFuse do
        local list = chickenList()
        local groups = {}
        for _, c in ipairs(list) do
            groups[c.typeId] = groups[c.typeId] or {}
            table.insert(groups[c.typeId], c)
        end
        for typeId, grp in pairs(groups) do
            if #grp >= 2 then
                local a, b = grp[1], grp[2]
                if a and b and a.id ~= b.id then
                    -- field map selects each fusion trait from the higher-level parent (a)
                    local fields = {}
                    for _, g in ipairs(FusionRules.GENE_KEYS or {}) do
                        table.insert(fields, { field = g, from = a.id })
                    end
                    pcallInvoke(R.FuseChickens, a.id, b.id, fields, nil, "a")
                    task.wait(1.5)
                end
                break
            end
        end
        task.wait(4.0)
    end
end

-- Auto Sell / Dupe cleanup: keep one chicken per typeId, sell the rest
local function runAutoSell()
    while hubAlive() and flags.autoSell do
        local list = chickenList()
        local activeId = roster().activeId
        local seen = {}
        local sell = {}
        for _, c in ipairs(list) do
            if c.id == activeId then
                seen[c.typeId] = true
            elseif seen[c.typeId] then
                table.insert(sell, c.id)
            else
                seen[c.typeId] = true
            end
        end
        if #sell > 0 then
            pcallInvoke(R.SellChickens, sell)
            task.wait(1.0)
        end
        task.wait(5.0)
    end
end

-- Auto Arena / Pit: ensure a team, fight when available, claim rank rewards
local function runAutoArena()
    while hubAlive() and flags.autoArena do
        local ok, view = pcall(function()
            local data = inv(R.ArenaGetView)
            return data and data.data, data
        end)
        if ok and type(view) == "table" then
            -- make sure a full team is saved (ArenaFight errors "no-team" otherwise)
            local teamIds = type(view.teamIds) == "table" and view.teamIds or {}
            local teamSize = type(view.teamSize) == "number" and view.teamSize or 3
            if #teamIds < teamSize and type(view.inventory) == "table" then
                local sorted = {}
                for _, c in ipairs(view.inventory) do
                    if type(c) == "table" and c.id then table.insert(sorted, c) end
                end
                table.sort(sorted, function(a, b)
                    return (a.powerBig or 0) > (b.powerBig or 0)
                end)
                local ids = {}
                for i = 1, math.min(teamSize, #sorted) do
                    table.insert(ids, sorted[i].id)
                end
                if #ids >= teamSize then
                    pcallInvoke(R.ArenaSetTeam, ids)
                    task.wait(0.8)
                end
            end
            -- claim rank rewards that are available
            if type(view.claimable) == "table" then
                for _, rewardId in ipairs(view.claimable) do
                    pcallInvoke(R.ArenaClaim, rewardId)
                    task.wait(0.8)
                end
            end
            -- start a battle when one is available and none is running
            if view.available and not view.hasActiveMatch then
                pcallInvoke(R.ArenaFight)
                task.wait(4.0)
            end
        end
        task.wait(3.0)
    end
end

------------------------------------------------------------------
-- CLAIMS loop
------------------------------------------------------------------

local function missionStateData()
    local ok2, missions = pcall(function() return client:get({"missions"}) end)
    local ok3, scrap = pcall(function() return client:get({"scrap"}) end)
    return {
        roster = roster(),
        towerBest = towerBest(),
        rebirthCount = rebirthCount(),
        recyclerLevel = (ok3 and scrap and scrap.recyclerLevel) or 0,
        missions = (ok2 and missions) or {},
    }
end

-- Auto Claim Missions: claim every mission whose progress meets the target
local function runClaimMissions()
    while hubAlive() and flags.claimMissions do
        local md = missionStateData()
        for _, scope in ipairs(MissionView.SCOPES) do
            local act = pcall(MissionView.active, scope)
            if type(act) == "table" then
                for _, m in ipairs(act) do
                    if m.kind == nil and MissionView.stateOf(md, m) == "ready" then
                        pcallInvoke(R.MissionClaim, m.id)
                        task.wait(0.5)
                    end
                end
            end
        end
        task.wait(4.0)
    end
end

-- Auto Claim Daily: streak day + session tiers
local function runClaimDaily()
    while hubAlive() and flags.claimDaily do
        local ok, daily = pcall(function() return client:get({"daily"}) end)
        if ok and daily then
            local claimed = daily.claimed or {}
            if not claimed["day"] and not claimed["d"] then
                pcallInvoke(R.DailyClaim, "day", nil)
                task.wait(0.6)
            end
            local played = daily.played or 0
            local session = daily.session or {}
            for j, k in ipairs(session) do
                if (not claimed["s" .. j]) and (k.at or 0) <= played then
                    pcallInvoke(R.DailyClaim, "session", j)
                    task.wait(0.6)
                end
            end
        end
        task.wait(5.0)
    end
end

-- Auto Claim Rebirth Milestones
local function runClaimRebirth()
    while hubAlive() and flags.claimRebirth do
        pcallInvoke(R.ClaimRebirthMilestones)
        task.wait(6.0)
    end
end

-- Auto Claim Pass: claim every claimable pass rung
local function runAutoClaimPass()
    while hubAlive() and flags.autoClaimPass do
        local ok, purs = pcall(function() return client:get({"purchases"}) end)
        local passes = (ok and purs and purs.passes) or {}
        -- invalid statuses fail harmlessly; attempt each unclaimed numeric rung
        for tier, rungs in pairs(passes) do
            if type(rungs) == "table" then
                for k, claimed in pairs(rungs) do
                    if (claimed == false or claimed == nil) and tonumber(k) then
                        pcallInvoke(R.PassClaim, tonumber(k), tier)
                        task.wait(0.8)
                    end
                end
            end
        end
        task.wait(6.0)
    end
end

-- Auto Claim Shop Dust: claim the daily shop dust reward
local function runAutoShopDust()
    while hubAlive() and flags.autoShopDust do
        pcallInvoke(R.ClaimShopDust)
        task.wait(15.0)
    end
end

------------------------------------------------------------------
-- MOVEMENT / UTILITY loops
------------------------------------------------------------------

-- Anti AFK (silent): nudge the character's root by an imperceptible amount each
-- interval. This counts as movement/activity to the server so the 20-minute
-- idle kick never fires, but there is no visible jumping at all.
local function runAntiAfk()
    local last = 0
    while hubAlive() and flags.antiAfk do
        local now = tick()
        if now - last >= 60 then
            last = now
            local hrp = getCharRoot()
            if hrp then
                local cf = hrp.CFrame
                pcall(function()
                    hrp.CFrame = cf * CFrame.new(0, 0, 0.001)
                end)
            end
        end
        task.wait(10)
    end
end

-- Auto Pet: repeatedly pet your chicken while it rests at the coop, building
-- the pet combo (comboWindow 2.2s, minInterval 0.26s) so the combo milestones
-- (up to several thousand per pet) keep paying out. Only fires when the
-- chicken is home (order "coop"); the server rejects pets mid-pit/campaign.
local function runAutoPet()
    while hubAlive() and flags.autoPet do
        if ChickenMode.order() == "coop" then
            pcall(Remotes.fire, R.PetChicken)
        end
        task.wait(0.35)
    end
end

-- Auto Chaos: march the chicken into the Center Ring (danger zone). Only sends
-- once the chicken is at full health so it never gets picked off the moment it
-- arrives. Fires the same SetChickenOrder remote the HUD's "TO CHAOS" button
-- uses; the server throttles it to ~0.3s so a slow cadence is plenty.
local function runAutoChaos()
    while hubAlive() and flags.chaos do
        local v = vitals()
        if (v.health or 1) >= 0.999 and ChickenMode.order() ~= "chaos" then
            pcall(Remotes.fire, R.SetChickenOrder, "chaos")
        end
        task.wait(0.8)
    end
end

-- Performance Mode: keeps 3D rendering ON, just trims graphics settings so the
-- client runs faster/higher fps. Turning the screen off entirely is left to
-- Ultra Performance Mode.
local function applyPerformance(on)
    if on then
        pcall(function() Lighting.GlobalShadows = false end)
        pcall(function() Lighting.Brightness = 1 end)
    else
        pcall(function() Lighting.GlobalShadows = true end)
    end
end

-- Ultra Performance Mode: turns 3D rendering off entirely for maximum fps, and
-- instead of the default blank view it shows a full black screen (via a
-- full-screen black overlay, so it is not white). Also applies the lighter
-- Performance trims and disables particles.
local ultraOverlay = nil
local function applyUltraPerformance(on)
    applyPerformance(on)
    if on then
        pcall(function() RunService:Set3dRenderingEnabled(false) end)
        pcall(function()
            for _, p in ipairs(Lighting:GetDescendants()) do
                if p:IsA("ParticleEmitter") or p:IsA("Beam") then
                    p.Enabled = false
                end
            end
        end)
        if not ultraOverlay then
            local sg = Instance.new("ScreenGui")
            sg.Name = "NexusUltraOverlay"
            sg.IgnoreGuiInset = true
            sg.DisplayOrder = 1e9
            local frame = Instance.new("Frame")
            frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
            frame.BackgroundTransparency = 0
            frame.BorderSizePixel = 0
            frame.Size = UDim2.fromScale(1, 1)
            frame.Parent = sg
            sg.Parent = Player:WaitForChild("PlayerGui")
            ultraOverlay = sg
        end
    else
        pcall(function() RunService:Set3dRenderingEnabled(true) end)
        if ultraOverlay then
            pcall(function() ultraOverlay:Destroy() end)
            ultraOverlay = nil
        end
    end
end

------------------------------------------------------------------
-- UI build
------------------------------------------------------------------
-- Hard clear any hub window left over from earlier executions (rejoins,
-- crash leftovers, queued reloads) so only ONE ever exists. We MUST call
-- Unload() on the previous window (not just destroy the GUI) so Rayfield
-- drops its internal PageLayout/tab registry — otherwise the next re-deploy's
-- CreateTab fails with "Rebirth Farm passed to PageLayout JumpTo is not part
-- of the layout". This Unload also runs on plain-loadstring rejoins, where
-- STATE.onCleanup never fires, which is the exact case that produced the bug.
local prevWin = getgenv().NexusHubWin
if prevWin then
    pcall(function() prevWin:Unload() end)
end
killAllNexusWindows()
getgenv().NexusHubWin = nil
local win = Rayfield:CreateWindow({
    Name = "NEXUS HUB",
    Subtitle = "Grow a Chicken Fighter",
    LoadingTitle = "NEXUS HUB",
    LoadingSubtitle = "by Real",
    ConfigurationSaving = { Enabled = false, FolderName = "NexusHub", FileName = "settings" },
    Discord = { Enabled = false },
    KeySystem = false,
    ToggleUIKeybind = Enum.KeyCode.LeftControl,
})
getgenv().NexusHubWin = win

-- on reload, tear down the previous run's window so windows don't stack
if STATE then
    STATE.onCleanup(function()
        pcall(function() if win then win:Unload() end end)
        killAllNexusWindows()
        pcall(function() if ultraOverlay then ultraOverlay:Destroy() end end)
        pcall(function() RunService:Set3dRenderingEnabled(true) end)
        getgenv().NexusHubWin = nil
    end)
end

-- toggle registration: { tab, section, name, flag, fn[, default] }
local toggles = {
    -- Rebirth Farm tab
    { "rfarm",  "Rebirth Farm","Auto Rebirth Farm",          "rebirthFarm",            runRebirthFarm },

    -- Farm tab
    { "farm",   "Farming",    "Auto Send Tower",            "sendTower",              runSendTower },
    { "farm",   "Farming",    "Auto Upgrade Feeder",        "upgradeFeeder",          runUpgradeFeeder },
    { "farm",   "Farming",    "Auto Buy Feeder",            "buyFeeder",              runBuyFeeder },
    { "farm",   "Farming",    "Auto Upgrade Coop",          "upgradeCoop",            runUpgradeCoop },
    { "farm",   "Farming",    "Auto Claim Egg Incubator",   "autoClaimEggIncubator",  runAutoClaimEggIncubator },
    { "farm",   "Farming",    "Auto Collect Eggs (walk)",   "autoCollectEggs",        runAutoCollectEggs },
    { "farm",   "Farming",    "Auto Upgrade Incubator",     "autoUpgradeIncubator",   runAutoUpgradeIncubator },
    { "farm",   "Farming",    "Auto Upgrade Recycler",      "upgradeRecycler",        runUpgradeRecycler },
    { "farm",   "Farming",    "Auto Pet",                   "autoPet",                runAutoPet },

    -- Misc / Claims
    { "misc",   "Claims",     "Auto Claim Missions",        "claimMissions",          runClaimMissions },
    { "misc",   "Claims",     "Auto Claim Daily",           "claimDaily",             runClaimDaily },
    { "misc",   "Claims",     "Auto Claim Rebirth Milestones","claimRebirth",         runClaimRebirth },
    { "misc",   "Claims",     "Auto Claim Pass",            "autoClaimPass",          runAutoClaimPass },
    { "misc",   "Claims",     "Auto Claim Shop Dust",       "autoShopDust",           runAutoShopDust },

    -- Misc / Inventory
    { "misc",   "Inventory",  "Auto Sell Duplicates",       "autoSell",               runAutoSell },
    { "misc",   "Inventory",  "Auto Fuse Chickens",         "autoFuse",               runAutoFuse },

    -- Misc / Utilities (Anti AFK is a loop; the two Performance toggles are
    -- immediate effects and are built separately below)
    { "misc",   "Utilities",  "Anti AFK",                   "antiAfk",                runAntiAfk },

    -- Fighting tab
    { "fight",  "Fighting",   "Auto Arena",                 "autoArena",              runAutoArena },
    { "fight",  "Fighting",   "Auto Chaos",                 "chaos",                  runAutoChaos },
}

local tabs = {
    rfarm = win:CreateTab({ Name = "Rebirth Farm", Icon = "flame" }),
    farm = win:CreateTab({ Name = "Farm", Icon = "home" }),
    misc = win:CreateTab({ Name = "Misc", Icon = "settings" }),
    fight = win:CreateTab({ Name = "Fighting", Icon = "sword" }),
    server = win:CreateTab({ Name = "Server", Icon = "globe" }),
}

local sections = {} -- tabKey -> sectionName -> section element (reused, created once)
for _, t in ipairs(toggles) do
    local tabKey, sectionName, name, flagKey, fn = t[1], t[2], t[3], t[4], t[5]
    sections[tabKey] = sections[tabKey] or {}
    if not sections[tabKey][sectionName] then
        sections[tabKey][sectionName] = tabs[tabKey]:CreateSection({ Name = sectionName })
    end
    tabs[tabKey]:CreateToggle({
        Name = name,
        Default = flags[flagKey] == true,
        Callback = function(v)
            flags[flagKey] = v
            if v then spawnLoop(flagKey, fn) end
        end,
    })
end

-- Auto Farm tower start strategy (Auto Send Tower uses this to pick the floor)
local strategyOptions = {
    "Straight To Your Frontier",
    "Warm Up At Floor",
    "Start From The Bottom",
}
tabs.farm:CreateDropdown({
    Name = "Tower Strategy",
    Options = strategyOptions,
    CurrentOption = { "Straight To Your Frontier" },
    MultipleOptions = false,
    Callback = function(opts)
        local picked = (type(opts) == "table" and opts[1]) or opts
        if picked == "Warm Up At Floor" then
            flags.towerStrategy = "warmup"
        elseif picked == "Start From The Bottom" then
            flags.towerStrategy = "bottom"
        else
            flags.towerStrategy = "frontier"
        end
    end,
})

-- Farm: how far to scan for world egg drops when Auto Collect Eggs is on
tabs.farm:CreateSlider({
    Name = "Collect Egg Scan Radius",
    Range = { 30, 500 },
    Increment = 10,
    Suffix = " studs",
    CurrentValue = flags.collectEggRadius or 200,
    Callback = function(v)
        flags.collectEggRadius = v
    end,
})

-- Misc / Utilities: the two performance toggles are immediate effects, not loops
tabs.misc:CreateToggle({
    Name = "Performance Mode",
    Default = flags.performance == true,
    Callback = function(v)
        flags.performance = v
        applyPerformance(v)
    end,
})
tabs.misc:CreateToggle({
    Name = "Ultra Performance Mode",
    Default = flags.ultraPerformance == true,
    Callback = function(v)
        flags.ultraPerformance = v
        applyUltraPerformance(v)
    end,
})

-- Misc / Hub: unload everything
tabs.misc:CreateSection({ Name = "Hub" })
tabs.misc:CreateButton({
    Name = "Unload Nexus Hub",
    Callback = function()
        -- kill every loop (hubAlive gates on this) and reset all flags
        getgenv().NX_HUB = false
        for k in pairs(flags) do flags[k] = false end
        -- restore rendering + remove the black overlay if it was on
        pcall(function() RunService:Set3dRenderingEnabled(true) end)
        pcall(function() if ultraOverlay then ultraOverlay:Destroy() end end)
        -- destroy the GUI (and any leftover hub windows)
        pcall(function() if win then win:Unload() end end)
        killAllNexusWindows()
        getgenv().NexusHubWin = nil
        getgenv().NX_HUB = nil
    end,
})

-- Config tab: removed (config auto save / load disabled)

-- Server tab: same-place server hopping + rejoin
tabs.server:CreateSection({ Name = "Server" })
tabs.server:CreateButton({
    Name = "Server Hop",
    Callback = function()
        serverHop()
    end,
})
tabs.server:CreateButton({
    Name = "Server Hop Low Players",
    Callback = function()
        serverHopLow()
    end,
})
tabs.server:CreateButton({
    Name = "Rejoin",
    Callback = function()
        rejoin()
    end,
})
tabs.server:CreateToggle({
    Name = "Auto Load on Teleport",
    Default = flags.autoLoadOnTeleport == true,
    Callback = function(v)
        flags.autoLoadOnTeleport = v
        if v then task.spawn(runQueueKeepAlive) end
    end,
})
tabs.server:CreateToggle({
    Name = "Auto Reconnect (rejoin on kick / 20 min idle)",
    Default = flags.autoReconnect == true,
    Callback = function(v)
        flags.autoReconnect = v
        if v then task.spawn(runAutoReconnect) end
    end,
})

-- apply any states already active this run (loops gate on these flags)
if flags.performance then applyPerformance(true) end
if flags.ultraPerformance then applyUltraPerformance(true) end
if flags.autoReconnect then task.spawn(runAutoReconnect) end
if flags.autoLoadOnTeleport then task.spawn(runQueueKeepAlive) end

getgenv().NX_HUB = true
