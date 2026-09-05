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
print("[Nexus] build snap-collect gen " .. tostring(gen))

-- Real's live-reload teardown handle, injected only when this runs through
-- live-reload. Under plain loadstring (rejoin/autoload) it's nil, so guard
-- every use. Read via getgenv so the static checker doesn't flag a global.
local STATE = getgenv().STATE

------------------------------------------------------------------
-- Services & requires
------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Player = Players.LocalPlayer
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
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
-- Sweep every hub window except the CURRENT generation's own. Windows get a
-- "NX_GEN" attribute stamped with the generation that built them, so a sweep
-- from any (possibly stale) copy can never destroy the live window: a stale
-- instance has an older gen and dies, a re-entrant sweep sees the current gen
-- and skips it. Pass force=true (the Unload button) to take everything down.
local function killAllNexusWindows(force)
    local myGen = getgenv().NEXUS_GEN
    for _, sg in ipairs(game:GetService("CoreGui"):GetDescendants()) do
        if sg:IsA("ScreenGui") or sg:IsA("LayerCollector") then
            pcall(function()
                local ours = sg:FindFirstChild("NEXUS HUB") or sg.Name == "Notifications" or sg.Name == "NexusHubUI"
                local sgGen = sg:GetAttribute("NX_GEN") or 0
                if ours and (force or sgGen < myGen) then
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
    autoCollectEggs = false,   -- instant-touch world egg drops (NestEggs), walk only as fallback
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

-----------------------------------------------------------------
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

local function _dump(o, seen)
    if type(o) ~= "table" then return tostring(o) end
    seen = seen or {}
    if seen[o] then return "(cycle)" end
    seen[o] = true
    local parts = {}
    for k, v in pairs(o) do
        parts[#parts + 1] = tostring(k) .. "=" .. _dump(v, seen)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
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
    local ok, src = pcall(readfile, "nexus_hub_v2.luau")
    if ok and type(src) == "string" then
        pcall(queue_on_teleport, "loadstring(readfile('nexus_hub_v2.luau'))()")
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

-- Tower start-floor helpers. The three Auto Farm tower strategies pick which
-- floor the run begins at:
--   "bottom"   -> start from floor 1 (full fresh run)
--   "frontier" -> start at the floor you'll challenge next (one above beaten best)
--   "warmup"   -> start a few floors below the frontier to build up power
-- The "Stats" spread the game/Apel shows is (Best 45 -> Frontier 46 -> Warm
-- up 41), i.e. frontier is one above your beaten best floor.
local TOWER_WARMUP_OFFSET = 5
local function towerFrontier()
    -- Highest challengeable floor: one above the beaten best.
    return towerBest() + 1
end
local function towerStartFloor()
    local front = towerFrontier()
    local s = flags.towerStrategy or "frontier"
    if s == "bottom" then
        return 1
    elseif s == "warmup" then
        return math.max(1, front - TOWER_WARMUP_OFFSET)
    else
        return front
    end
end

-- Start a tower run at the given floor, mirroring exactly what the game's
-- controller does (ElevatorController/CampaignController.startRun):
--   1) TowerElevator:InvokeServer(floor)  picks the starting floor for the run
--   2) ChickenMode.order("tower")         switches the chicken into tower mode
--   3) TowerStart:InvokeServer()          actually begins the run
-- TowerElevator alone only SELECTS the floor; the run never starts until
-- TowerStart fires, which is why the chicken stayed at the corral before.
-- Returns true if the whole sequence invoked without error.
local function towerStartRemote(floor)
    local ok, err = pcall(function()
        inv(R.TowerElevator, floor)
        ChickenMode.order("tower")
        inv(R.TowerStart)
    end)
    if not ok then
        warn(string.format("[NEXUS] towerStart FAILED (floor %s): %s", tostring(floor), tostring(err)))
    end
    return ok, err
end

-- Wait up to ~3s for the chicken to actually leave the corral after a tower
-- start, i.e. confirm the run really began on the floor we picked. Returns
-- true once the chicken is no longer resting at the corral.
local function waitForStart()
    for _ = 1, 6 do
        if not atCorral() then return true end
        task.wait(0.5)
    end
    return false
end

-- Smart tower start used by Rebirth Farm. Always try the highest reachable
-- (frontier) floor first; if that fails to fire, step down to warm-up
-- (frontier minus a small offset), and if that also fails, start at floor 1.
-- Each attempt is fired and then we WAIT for the chicken to actually leave
-- the corral (confirming the run started on that floor); only if it never
-- leaves do we try the next candidate. This avoids firing all three
-- back-to-back, which made the server honor only the last one (floor 1).
local function towerStartSmart()
    if flags.towerStrategy == "bottom" then
        towerStartRemote(1)
        return waitForStart()
    end
    local front = towerFrontier()
    local warm = math.max(1, front - TOWER_WARMUP_OFFSET)
    for _, floor in ipairs({ front, warm, 1 }) do
        towerStartRemote(floor)
        local started = waitForStart()
        if started then
            return true, floor
        end
    end
    return false
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
            task.spawn(function() towerStartRemote(towerStartFloor()) end)
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
local towerStartBusy = false
local function runRebirthFarm()
    if not rfContinueConn then
        rfContinueConn = Remotes.onClient(R.TowerContinueOffer, function()
            task.spawn(function() pcall(Remotes.fire, R.TowerContinueDecline) end)
        end)
    end
    -- Feeder loop: continuous, gated only on the flag. Focuses on exactly 2
    -- feeders: buys one whenever a coop slot is free (never expands the coop,
    -- never a 3rd feeder), then raises both to max as fast as the server round
    -- trip allows. Not throttled by the tower/rebirth pacing.
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
    -- State machine:
    --   * meeting the rebirth requirement -> surrender the chicken home, then
    --     rebirth once it is resting at the corral.
    --   * not yet meeting it -> START A RUN ONLY when the chicken is resting
    --     at the corral AND back at full health, so it always waits until it
    --     has fully recovered before heading to the tower again. While the
    --     chicken is out fighting (not at the corral) the gate blocks any
    --     re-fire, so we never send it straight back mid-transition.
    while hubAlive() and flags.rebirthFarm do
        if rebirthReady() then
            if not atCorral() then
                pcallInvoke(R.TowerSurrender)
                task.wait(1.0)
            elseif atCorral() then
                pcallInvoke(R.Rebirth)
                task.wait(3)
            end
        else
            if atCorral() and (vitals().health or 1) >= 0.999 and not towerStartBusy then
                towerStartBusy = true
                task.spawn(function()
                    pcall(function() towerStartSmart() end)
                    towerStartBusy = false
                end)
            end
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
-- Steal an egg by snapping the REAL, still-parented HumanoidRootPart onto it.
-- Verified 2026-09-05 (placeVersion 996): the server's egg grant fires only on
-- a genuine Touched by the player's actual character part - so the character
-- truly has to be at the egg. firetouchinterest, phantom parts, anchored/
-- physics proxies and unparented (Parent = nil) roots all fail; unparented
-- positions never replicate, so the server never sees them. A snap keeps the
-- root parented, so the server sees the character ON the egg, grants it, then
-- corrects the teleport by snapping the character back (a ~0.3s flicker) -
-- without kicking (7 rapid steals observed, no kick; after 3 consecutive
-- rejections the collector disables snapping entirely for the session). The
-- hold is capped at 0.28s: an egg either registers within ~2 server ticks or
-- it won't, and shorter holds keep the hop barely visible. The whole bound
-- character model moves as one parented assembly (no detached parts) - snap
-- on, hold, snap straight back. Returns true when the egg vanished (server
-- collected it).
local function snapCollect(egg)
    local hrp = getCharRoot()
    if not egg or not egg.Parent or not hrp then return false end
    local saved = hrp.CFrame
    hrp.CFrame = CFrame.new(egg.Position + Vector3.new(0, 1.0, 0))
    local deadline = os.clock() + 0.28
    local collected = false
    while os.clock() < deadline and hubAlive() do
        task.wait(0.03)
        if not egg.Parent then collected = true break end
    end
    pcall(function() hrp.CFrame = saved end)
    task.wait(0.05)
    return collected
end

local function runAutoCollectEggs()
    local snapStrikes = 0
    local lastSnap = 0
    while hubAlive() and flags.autoCollectEggs do
        -- Snap-only collector: every owned egg out of natural range (~7 studs)
        -- is stolen with the fast 0.28s snap-flicker - snap the whole bound
        -- character model onto the egg and instantly back, never walking or
        -- gliding anywhere. Eggs inside the ~7-stud zone the server collects by
        -- itself while the character idle. There is deliberately NO falling back
        -- to walking/gliding anymore.
        --
        -- One guard stays: the server's teleport-strike counter (observed
        -- 2026-09-05: a dense always-on loop of ~1 steal/2s triggers a kick; 7
        -- steals spread over minutes does not). Max one snap per SNAP_GAP, and
        -- after 3 consecutive rejections the snap path is disabled for the
        -- session (eggs are simply left for the next time the toggle is on).
        if getCharRoot() and snapStrikes < 3 then
            local list = scanNestEggs(flags.collectEggRadius)
            local hrp = getCharRoot()
            for _, egg in ipairs(list) do
                if not hubAlive() then break end
                if egg.Parent and (hrp.Position - egg.Position).Magnitude > 7 then
                    if os.clock() - lastSnap >= 6 then
                        if snapCollect(egg) then
                            lastSnap = os.clock()
                            snapStrikes = 0
                        else
                            snapStrikes = snapStrikes + 1
                        end
                    else
                        -- paced out; the next distant egg can wait
                        break
                    end
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
-- UI build — custom gold/silver window (no Rayfield)
------------------------------------------------------------------
-- Hard clear any hub window left over from earlier executions (rejoins,
-- crash leftovers, queued reloads) so only ONE ever exists. Every execution
-- rebuilds a single ScreenGui; the guard sweeps CoreGui for our own name plus
-- any Rayfield leftovers, which also covers plain-loadstring rejoins where
-- STATE.onCleanup never fires.
killAllNexusWindows()
getgenv().NexusHubWin = nil

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")

local T = {
    bg      = Color3.fromRGB(17, 17, 25),
    panel   = Color3.fromRGB(26, 26, 38),
    panel2  = Color3.fromRGB(33, 33, 48),
    sidebar = Color3.fromRGB(20, 20, 29),
    gold    = Color3.fromRGB(255, 203, 96),
    goldLo  = Color3.fromRGB(150, 118, 55),
    text    = Color3.fromRGB(236, 236, 244),
    textDim = Color3.fromRGB(153, 153, 171),
    red     = Color3.fromRGB(235, 84, 84),
    yellow  = Color3.fromRGB(232, 190, 66),
    green   = Color3.fromRGB(96, 214, 138),
}

local function mk(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props) do inst[k] = v end
    if parent ~= nil then inst.Parent = parent end
    return inst
end

local function rounded(obj, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r)
    c.Parent = obj
end

-- ---------------- root + bubble + window ----------------
local sg = mk("ScreenGui", {
    Name = "NexusHubUI",
    DisplayOrder = 999,
    IgnoreGuiInset = true,
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    Parent = game:GetService("CoreGui"),
})
sg:SetAttribute("NX_GEN", gen)
getgenv().NexusHubWin = sg

local bubble = mk("TextButton", {
    Name = "Bubble",
    Size = UDim2.fromOffset(58, 58),
    Position = UDim2.new(1, -82, 1, -82),
    BackgroundColor3 = T.gold,
    BorderSizePixel = 0,
    Text = "N",
    Font = Enum.Font.GothamBold,
    TextSize = 24,
    TextColor3 = Color3.fromRGB(22, 22, 28),
    AutoButtonColor = false,
    ZIndex = 5,
    Parent = sg,
})
rounded(bubble, 29)
mk("UIStroke", { Color = T.goldLo, Thickness = 2, Transparency = 0.45, Parent = bubble })

local windowFrame = mk("Frame", {
    Name = "Window",
    Size = UDim2.fromOffset(750, 480),
    Position = UDim2.new(0.5, -375, 0.5, -240),
    BackgroundColor3 = Color3.fromRGB(24, 26, 40),
    BackgroundTransparency = 0.3,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    ZIndex = 6,
    Parent = sg,
})
rounded(windowFrame, 12)
mk("UIStroke", { Color = T.goldLo, Thickness = 1, Transparency = 0.5, Parent = windowFrame })
-- translucent glass: edges feather out (more transparent), the middle stays
-- readable. Composite alpha = (1 - 0.3) * (1 - gradient) per pixel.
mk("UIGradient", {
    Rotation = 90,
    Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.55),
        NumberSequenceKeypoint.new(0.45, 0.14),
        NumberSequenceKeypoint.new(0.55, 0.14),
        NumberSequenceKeypoint.new(1, 0.55),
    }),
    Parent = windowFrame,
})

-- Window open/close is animated with a short TweenService zoom so the hub
-- never just cuts in/out: the frame shrinks about its own center while closing
-- and grows back out on reopen, then is re-hidden once the tween finishes. No
-- GroupTransparency — this client's Frame does not expose it. Size/Position
-- are tweened between UDim2s computed arithmetically from the screen size so
-- the center is always preserved and there are no stale Absolute* reads.
local windowVisible = true
local windowTween = nil
local winRestore = nil -- { size, pos } (UDim2) captured on close, restored on reopen

local function scrSize()
    local s = GuiService:GetScreenResolution()
    return s.X, s.Y
end

local function absX(ud, W) return ud.X.Scale * W + ud.X.Offset end
local function absY(ud, H) return ud.Y.Scale * H + ud.Y.Offset end

-- Two UDim2s (size, pos) of a rect scaled by f about its center, as absolute
-- offsets. windowFrame's parent is the full-screen ScreenGui (anchor 0,0), so
-- Position = screen offset directly.
local function scaledAboutCenter(sizeUD, posUD, f, W, H)
    local szx, szy = absX(sizeUD, W), absY(sizeUD, H)
    local px, py = absX(posUD, W), absY(posUD, H)
    local cx, cy = px + szx * 0.5, py + szy * 0.5
    local mx, my = szx * f, szy * f
    return UDim2.fromOffset(mx, my), UDim2.fromOffset(cx - mx * 0.5, cy - my * 0.5)
end

local function showWindow(open, animate)
    if open == windowVisible then return end
    windowVisible = open
    if windowTween then
        pcall(function() windowTween:Cancel() end)
        windowTween = nil
    end
    if not animate then
        windowFrame.Visible = open
        return
    end
    local W, H = scrSize()
    if open then
        local goalSize = winRestore and winRestore.size or windowFrame.Size
        local goalPos = winRestore and winRestore.pos or windowFrame.Position
        winRestore = nil
        -- normalize the goal to absolute offsets (a max'd window keeps scale),
        -- then start small about its center and grow into it.
        goalSize = UDim2.fromOffset(absX(goalSize, W), absY(goalSize, H))
        goalPos = UDim2.fromOffset(absX(goalPos, W), absY(goalPos, H))
        windowFrame.Visible = true
        local startSize, startPos = scaledAboutCenter(goalSize, goalPos, 0.88, W, H)
        windowFrame.Size = startSize
        windowFrame.Position = startPos
        windowTween = TweenService:Create(windowFrame,
            TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            { Size = goalSize, Position = goalPos })
        windowTween:Play()
    else
        winRestore = { size = windowFrame.Size, pos = windowFrame.Position }
        -- normalize the current rect so the shrink starts from true offsets
        local curS = UDim2.fromOffset(absX(windowFrame.Size, W), absY(windowFrame.Size, H))
        local curP = UDim2.fromOffset(absX(windowFrame.Position, W), absY(windowFrame.Position, H))
        windowFrame.Size = curS
        windowFrame.Position = curP
        local targetSize, targetPos = scaledAboutCenter(curS, curP, 0.86, W, H)
        windowTween = TweenService:Create(windowFrame,
            TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            { Size = targetSize, Position = targetPos })
        local tw = windowTween
        tw.Completed:Connect(function()
            if windowVisible == false then
                windowFrame.Visible = false
            end
        end)
        windowTween:Play()
    end
end

-- ---------------- top bar ----------------
local topbar = mk("Frame", {
    Name = "TopBar",
    Size = UDim2.new(1, 0, 0, 34),
    BackgroundColor3 = T.panel,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    ZIndex = 7,
    Parent = windowFrame,
})
rounded(topbar, 12)

local function dotButton(x, color)
    local b = mk("TextButton", {
        Name = "Dot",
        Size = UDim2.fromOffset(13, 13),
        Position = UDim2.new(0, x, 0.5, -7),
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 10,
        Parent = topbar,
    })
    rounded(b, 7)
    return b
end
local closeBtn = dotButton(12, T.red)
local minBtn = dotButton(32, T.yellow)
local maxBtn = dotButton(52, T.green)

mk("TextLabel", {
    Name = "WinTitle",
    Size = UDim2.new(1, -80, 0, 18),
    Position = UDim2.new(0, 76, 0, 3),
    BackgroundTransparency = 1,
    Text = "NEXUS HUB",
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    TextColor3 = T.gold,
    TextXAlignment = Enum.TextXAlignment.Center,
    ZIndex = 8,
    Parent = topbar,
})
mk("TextLabel", {
    Name = "WinSub",
    Size = UDim2.new(1, -80, 0, 12),
    Position = UDim2.new(0, 76, 0, 20),
    BackgroundTransparency = 1,
    Text = "Grow a Chicken Fighter",
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = T.textDim,
    TextXAlignment = Enum.TextXAlignment.Center,
    ZIndex = 8,
    Parent = topbar,
})

-- window drag: a full-topbar invisible button so dragging works anywhere on
-- the bar (the title labels above would otherwise swallow the input); the
-- macOS dots sit above it so they stay clickable.
local winDrag, winOff = false, Vector2.new()
mk("TextButton", {
    Name = "Drag",
    Size = UDim2.new(1, 0, 0, 34),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    Text = "",
    ZIndex = 9,
    Parent = topbar,
}).InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 then
        winDrag = true
        winOff = UserInputService:GetMouseLocation() - windowFrame.AbsolutePosition
    end
end)

-- macOS-style dots: red hides the window (bubble reopens), yellow hides too,
-- green maximizes / restores the window.
local winMax = false
local winBaseSize = Vector2.new(750, 480)
local winBasePos = UDim2.new(0.5, -375, 0.5, -240)
closeBtn.MouseButton1Click:Connect(function() showWindow(false, true) end)
minBtn.MouseButton1Click:Connect(function() showWindow(false, true) end)
maxBtn.MouseButton1Click:Connect(function()
    -- maximizing forces the window fully open, canceling any zoom mid-flight
    if windowTween then
        pcall(function() windowTween:Cancel() end)
        windowTween = nil
    end
    windowVisible = true
    windowFrame.Visible = true
    winMax = not winMax
    if winMax then
        local vp = GuiService:GetScreenResolution()
        local w, h = vp.X * 0.86, vp.Y * 0.86
        windowFrame.Size = UDim2.fromOffset(w, h)
        windowFrame.Position = UDim2.new(0.5, -w / 2, 0.5, -h / 2)
    else
        windowFrame.Size = UDim2.fromOffset(winBaseSize.X, winBaseSize.Y)
        windowFrame.Position = winBasePos
    end
end)

-- bubble: RIGHT-click toggles the window; LEFT-click / touch TAP toggles it
-- too (unless it was a drag). Pressing the bubble also starts a drag so you
-- can move it, and the drag is told apart from a tap by travel distance.
bubble.MouseButton2Click:Connect(function()
    showWindow(not windowVisible, true)
end)

local bubblePos0 = Vector2.new()
local bubbleDrag, bubbleGrabMouse, bubbleGrabPos = false, Vector2.new(), UDim2.new()
bubble.InputBegan:Connect(function(inp)
    local t = inp.UserInputType
    if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
        bubbleDrag = true
        bubblePos0 = UserInputService:GetMouseLocation()
        bubbleGrabMouse = bubblePos0
        bubbleGrabPos = bubble.Position
    end
end)
bubble.Activated:Connect(function()
    if (UserInputService:GetMouseLocation() - bubblePos0).Magnitude > 12 then
        return -- it was a drag, not a tap
    end
    showWindow(not windowVisible, true)
end)

-- any input release ends every drag
UserInputService.InputEnded:Connect(function(inp)
    local t = inp.UserInputType
    if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
        bubbleDrag, winDrag = false, false
    end
end)

-- keep bubble & window inside the viewport while dragging (clamped)
RunService.RenderStepped:Connect(function()
    local vp = GuiService:GetScreenResolution()
    if bubbleDrag then
        local m = UserInputService:GetMouseLocation()
        bubble.Position = UDim2.new(
            0, math.clamp(bubbleGrabPos.X.Offset + (m.X - bubbleGrabMouse.X), 0, vp.X - 58),
            0, math.clamp(bubbleGrabPos.Y.Offset + (m.Y - bubbleGrabMouse.Y), 0, vp.Y - 58))
    end
    if winDrag and windowFrame.Visible then
        local m = UserInputService:GetMouseLocation()
        local sz = windowFrame.AbsoluteSize
        windowFrame.Position = UDim2.fromOffset(
            math.clamp(m.X - winOff.X, -sz.X + 90, vp.X - 90),
            math.clamp(m.Y - winOff.Y, -sz.Y + 70, vp.Y - 70))
    end
end)

-- LeftControl toggles the window too
UserInputService.InputBegan:Connect(function(inp, gameProcessed)
    if gameProcessed then return end
    if inp.KeyCode == Enum.KeyCode.LeftControl then
        showWindow(not windowVisible, true)
    end
end)

-- ---------------- sidebar ----------------
local sidebar = mk("Frame", {
    Name = "Sidebar",
    Position = UDim2.new(0, 0, 0, 34),
    Size = UDim2.new(0, 190, 1, -34),
    BackgroundColor3 = T.sidebar,
    BackgroundTransparency = 0.24,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    ZIndex = 7,
    Parent = windowFrame,
})
rounded(sidebar, 12)

mk("TextLabel", {
    Size = UDim2.new(1, 0, 0, 24),
    Position = UDim2.new(0, 0, 0, 26),
    BackgroundTransparency = 1,
    Text = "NEXUS HUB",
    Font = Enum.Font.GothamBold,
    TextSize = 17,
    TextColor3 = T.gold,
    ZIndex = 8,
    Parent = sidebar,
})
mk("TextLabel", {
    Size = UDim2.new(1, 0, 0, 14),
    Position = UDim2.new(0, 0, 0, 50),
    BackgroundTransparency = 1,
    Text = "Grow a Chicken Fighter",
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = T.textDim,
    ZIndex = 8,
    Parent = sidebar,
})

local tabOrder = {
    { key = "home",   label = "Home" },
    { key = "rfarm",  label = "Rebirth Farm" },
    { key = "farm",   label = "Farm" },
    { key = "misc",   label = "Misc" },
    { key = "fight",  label = "Fighting" },
    { key = "server", label = "Server" },
}
local tabBtns = {}
local tabFrames = {}
local activeTab = nil
local syncCanvas -- forward declaration; defined below

local tabList = mk("Frame", {
    Name = "TabList",
    Position = UDim2.new(0, 0, 0, 84),
    Size = UDim2.new(1, 0, 1, -150),
    BackgroundTransparency = 1,
    ZIndex = 8,
    Parent = sidebar,
})
local tabLayout = mk("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = tabList })
tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

local function switchTab(key)
    activeTab = key
    for k, f in pairs(tabFrames) do f.Visible = (k == key) end
    for k, b in pairs(tabBtns) do
        local on = (k == key)
        local accent = b:FindFirstChildOfClass("Frame")
        b.BackgroundTransparency = on and 0 or 1
        b.TextColor3 = on and T.text or T.textDim
        if accent then accent.BackgroundTransparency = on and 0 or 1 end
    end
    pcall(syncCanvas)
end

for i, t in ipairs(tabOrder) do
    local b = mk("TextButton", {
        Name = "Tab_" .. t.key,
        Size = UDim2.new(1, -22, 0, 34),
        LayoutOrder = i,
        BackgroundColor3 = T.panel2,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Text = t.label,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        TextColor3 = T.textDim,
        AutoButtonColor = false,
        ZIndex = 9,
        Parent = tabList,
    })
    rounded(b, 17)
    mk("Frame", {
        Size = UDim2.fromOffset(3, 18),
        Position = UDim2.new(0, 4, 0.5, -9),
        BackgroundColor3 = T.gold,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 10,
        Parent = b,
    }) -- left accent bar, revealed when the tab is active
    tabBtns[t.key] = b
    b.MouseButton1Click:Connect(function() switchTab(t.key) end)
end

-- profile footer: local player's headshot thumbnail + display name
local profile = mk("Frame", {
    Name = "Profile",
    Position = UDim2.new(0, 10, 1, -62),
    Size = UDim2.new(1, -20, 0, 52),
    BackgroundColor3 = T.panel,
    BackgroundTransparency = 0.28,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    ZIndex = 9,
    Parent = sidebar,
})
rounded(profile, 26)

local avId = Player and Player.UserId or 0
local avatar = mk("ImageLabel", {
    Name = "Avatar",
    Size = UDim2.fromOffset(38, 38),
    Position = UDim2.new(0, 7, 0.5, -19),
    BackgroundColor3 = Color3.fromRGB(14, 14, 20),
    BackgroundTransparency = 0.6,
    Image = "rbxthumb://type=AvatarHeadShot&id=" .. avId .. "&w=150&h=150",
    ScaleType = Enum.ScaleType.Crop,
    ZIndex = 10,
    Parent = profile,
})
rounded(avatar, 19)
mk("UIStroke", { Color = T.gold, Thickness = 1, Transparency = 0.35, Parent = avatar })

mk("TextLabel", {
    Name = "DisplayName",
    Size = UDim2.new(1, -54, 0, 18),
    Position = UDim2.new(0, 52, 0, 7),
    BackgroundTransparency = 1,
    Text = Player and Player.DisplayName or "…",
    Font = Enum.Font.GothamBold,
    TextSize = 13,
    TextColor3 = T.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    ZIndex = 10,
    Parent = profile,
})
mk("TextLabel", {
    Name = "Username",
    Size = UDim2.new(1, -54, 0, 14),
    Position = UDim2.new(0, 52, 0, 28),
    BackgroundTransparency = 1,
    Text = Player and ("@" .. Player.Name) or "",
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextColor3 = T.textDim,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    ZIndex = 10,
    Parent = profile,
})

-- ---------------- content ----------------
local content = mk("ScrollingFrame", {
    Name = "Content",
    Position = UDim2.new(0, 190, 0, 34),
    Size = UDim2.new(1, -190, 1, -34),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = T.goldLo,
    CanvasSize = UDim2.fromOffset(0, 0),
    ZIndex = 7,
    Parent = windowFrame,
})

for _, t in ipairs(tabOrder) do
    local f = mk("Frame", {
        Name = "Page_" .. t.key,
        Size = UDim2.new(1, -18, 0, 0),
        Position = UDim2.fromOffset(0, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 8,
        Visible = false,
        Parent = content,
    })
    mk("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = f })
    tabFrames[t.key] = f
end

-- keep the scroll canvas sized to whichever page is shown
syncCanvas = function()
    local page = tabFrames[activeTab]
    if not page then return end
    local lay = page:FindFirstChildOfClass("UIListLayout")
    local h = lay and lay.AbsoluteContentSize.Y or 0
    page.Size = UDim2.new(1, -18, 0, h)
    content.CanvasSize = UDim2.fromOffset(0, h + 14)
end
task.spawn(function()
    while hubAlive() and content do
        pcall(syncCanvas)
        task.wait(0.25)
    end
end)

-- ---------------- component builders ----------------
local orderFor = {}
local function layoutOrder(page)
    local o = (orderFor[page] or 0) + 1
    orderFor[page] = o
    return o
end

local function addSection(page, title)
    return mk("TextLabel", {
        Name = "Header",
        Size = UDim2.new(1, -8, 0, 26),
        BackgroundTransparency = 1,
        Text = string.upper(title),
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = T.gold,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = layoutOrder(page),
        ZIndex = 9,
        Parent = page,
    })
end

local function addToggle(page, name, flagKey, onChange, defaultOn)
    local on = defaultOn
    if on == nil then on = flags[flagKey] == true end
    local row = mk("Frame", {
        Name = "Row_" .. name,
        Size = UDim2.new(1, 0, 0, 40),
        BackgroundColor3 = T.panel,
        BorderSizePixel = 0,
        LayoutOrder = layoutOrder(page),
        ZIndex = 9,
        Parent = page,
    })
    rounded(row, 9)
    local lbl = mk("TextLabel", {
        Size = UDim2.new(1, -66, 0, 40),
        BackgroundTransparency = 1,
        Text = name,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        TextColor3 = T.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 10,
        Parent = row,
    })
    local track = mk("Frame", {
        Name = "Switch",
        Size = UDim2.fromOffset(44, 24),
        Position = UDim2.new(1, -56, 0.5, -12),
        BackgroundColor3 = Color3.fromRGB(60, 60, 76),
        BorderSizePixel = 0,
        ZIndex = 11,
        Parent = row,
    })
    rounded(track, 12)
    local knob = mk("Frame", {
        Name = "Knob",
        Size = UDim2.fromOffset(18, 18),
        Position = UDim2.new(0, 3, 0, 3),
        BackgroundColor3 = Color3.fromRGB(240, 240, 240),
        BorderSizePixel = 0,
        ZIndex = 12,
        Parent = track,
    })
    rounded(knob, 9)
    local function paint()
        track.BackgroundColor3 = on and T.gold or Color3.fromRGB(60, 60, 76)
        knob.BackgroundColor3 = on and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(235, 235, 235)
        knob.Position = on and UDim2.new(1, -21, 0, 3) or UDim2.new(0, 3, 0, 3)
        lbl.TextColor3 = on and Color3.fromRGB(255, 255, 255) or T.text
    end
    local function flip()
        on = not on
        flags[flagKey] = on
        paint()
        if onChange then pcall(onChange, on) end
    end
    mk("TextButton", {
        Size = UDim2.new(1, 0, 0, 40),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Text = "",
        ZIndex = 13,
        Parent = row,
    }).MouseButton1Click:Connect(flip)
    paint()
    return function() return on end
end

local function addDropdown(page, name, options, currentIndex, onChange)
    local row = mk("Frame", {
        Name = "Drop_" .. name,
        Size = UDim2.new(1, 0, 0, 40),
        BackgroundColor3 = T.panel,
        BorderSizePixel = 0,
        LayoutOrder = layoutOrder(page),
        ZIndex = 9,
        Parent = page,
    })
    rounded(row, 9)
    mk("TextLabel", {
        Size = UDim2.new(1, -176, 0, 40),
        BackgroundTransparency = 1,
        Text = name,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        TextColor3 = T.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 10,
        Parent = row,
    })
    local box = mk("TextButton", {
        Name = "Box",
        Size = UDim2.fromOffset(168, 28),
        Position = UDim2.new(1, -176, 0.5, -14),
        BackgroundColor3 = T.panel2,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 11,
        Parent = row,
    })
    rounded(box, 7)
    local boxText = mk("TextLabel", {
        Size = UDim2.new(1, -22, 0, 28),
        Position = UDim2.new(0, 8, 0, 0),
        BackgroundTransparency = 1,
        Text = tostring(options[currentIndex] or ""),
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextColor3 = T.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 12,
        Parent = box,
    })
    mk("TextLabel", {
        Size = UDim2.fromOffset(16, 28),
        Position = UDim2.new(1, -18, 0, 0),
        BackgroundTransparency = 1,
        Text = "▾",
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = T.gold,
        ZIndex = 12,
        Parent = box,
    })
    local open = false
    local popup = mk("Frame", {
        Name = "Popup",
        Size = UDim2.fromOffset(168, #options * 30),
        Position = UDim2.new(1, -176, 0, 34),
        BackgroundColor3 = T.panel2,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 30,
        Parent = row,
    })
    rounded(popup, 7)
    for i, opt in ipairs(options) do
        mk("TextButton", {
            Size = UDim2.new(1, 0, 0, 29),
            Position = UDim2.new(0, 0, 0, (i - 1) * 30),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Text = opt,
            Font = Enum.Font.Gotham,
            TextSize = 12,
            TextColor3 = T.text,
            AutoButtonColor = false,
            ZIndex = 31,
            Parent = popup,
        }).MouseButton1Click:Connect(function()
            currentIndex = i
            boxText.Text = opt
            open = false
            popup.Visible = false
            row.ZIndex = 9
            if onChange then pcall(onChange, opt, i) end
        end)
    end
    box.MouseButton1Click:Connect(function()
        open = not open
        popup.Visible = open
        row.ZIndex = open and 24 or 9
    end)
    return row
end

local function addSlider(page, name, minV, maxV, step, suffix, current, onChange)
    local row = mk("Frame", {
        Name = "Slider_" .. name,
        Size = UDim2.new(1, 0, 0, 58),
        BackgroundColor3 = T.panel,
        BorderSizePixel = 0,
        LayoutOrder = layoutOrder(page),
        ZIndex = 9,
        Parent = page,
    })
    rounded(row, 9)
    mk("TextLabel", {
        Size = UDim2.new(1, -140, 0, 20),
        Position = UDim2.new(0, 0, 0, 6),
        BackgroundTransparency = 1,
        Text = name,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        TextColor3 = T.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 10,
        Parent = row,
    })
    local valLbl = mk("TextLabel", {
        Size = UDim2.fromOffset(120, 20),
        Position = UDim2.new(1, -126, 0, 6),
        BackgroundTransparency = 1,
        Text = "",
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = T.gold,
        TextXAlignment = Enum.TextXAlignment.Right,
        ZIndex = 10,
        Parent = row,
    })
    local bar = mk("Frame", {
        Name = "Bar",
        Size = UDim2.new(1, -20, 0, 5),
        Position = UDim2.new(0, 10, 0, 40),
        BackgroundColor3 = Color3.fromRGB(60, 60, 76),
        BorderSizePixel = 0,
        ZIndex = 11,
        Parent = row,
    })
    rounded(bar, 3)
    local fill = mk("Frame", {
        Name = "Fill",
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = T.gold,
        BorderSizePixel = 0,
        ZIndex = 12,
        Parent = bar,
    })
    rounded(fill, 3)
    local knob = mk("TextButton", {
        Name = "Knob",
        Size = UDim2.fromOffset(16, 16),
        Position = UDim2.new(0, -8, 0.5, -8),
        BackgroundColor3 = T.gold,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 13,
        Parent = bar,
    })
    local val = math.clamp(math.round(current / step) * step, minV, maxV)
    local function fromMouse()
        local m = UserInputService:GetMouseLocation()
        local x = m.X - bar.AbsolutePosition.X
        local f = math.clamp(x / math.max(1, bar.AbsoluteSize.X), 0, 1)
        val = math.clamp(minV + math.round((maxV - minV) * f / step) * step, minV, maxV)
    end
    local function paint()
        local frac = (val - minV) / math.max(1, maxV - minV)
        fill.Size = UDim2.fromScale(frac, 1)
        knob.Position = UDim2.new(frac, -8, 0.5, -8)
        valLbl.Text = tostring(val) .. suffix
    end
    local sliding = false
    bar.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then
            sliding = true
            fromMouse()
            paint()
            if onChange then pcall(onChange, val) end
        end
    end)
    knob.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then
            sliding = true
            fromMouse()
            paint()
            if onChange then pcall(onChange, val) end
        end
    end)
    UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then sliding = false end
    end)
    RunService.RenderStepped:Connect(function()
        if sliding then
            fromMouse()
            paint()
            if onChange then pcall(onChange, val) end
        end
    end)
    paint()
    return row
end

local function addButton(page, name, onClick)
    local b = mk("TextButton", {
        Name = "Btn_" .. name,
        Size = UDim2.new(1, 0, 0, 40),
        BackgroundColor3 = T.panel,
        BorderSizePixel = 0,
        Text = name,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        TextColor3 = T.gold,
        AutoButtonColor = false,
        LayoutOrder = layoutOrder(page),
        ZIndex = 9,
        Parent = page,
    })
    rounded(b, 9)
    b.MouseEnter:Connect(function() b.BackgroundColor3 = T.panel2 end)
    b.MouseLeave:Connect(function() b.BackgroundColor3 = T.panel end)
    b.MouseButton1Click:Connect(function()
        if onClick then pcall(onClick) end
    end)
    return b
end

-- ---------------- Home tab: introduction ----------------
addSection(tabFrames.home, "Introduction")
local introCard = mk("Frame", {
    Name = "IntroCard",
    Size = UDim2.new(1, 0, 0, 236),
    BackgroundColor3 = T.panel,
    BorderSizePixel = 0,
    LayoutOrder = layoutOrder(tabFrames.home),
    ZIndex = 9,
    Parent = tabFrames.home,
})
rounded(introCard, 9)

mk("TextLabel", {
    Size = UDim2.new(1, -32, 0, 30),
    Position = UDim2.new(0, 16, 0, 12),
    BackgroundTransparency = 1,
    Text = "NEXUS HUB",
    Font = Enum.Font.GothamBold,
    TextSize = 18,
    TextColor3 = T.text,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 10,
    Parent = introCard,
})
mk("TextLabel", {
    Size = UDim2.new(1, -32, 0, 36),
    Position = UDim2.new(0, 16, 0, 42),
    BackgroundTransparency = 1,
    Text = "Welcome! Nexus Hub is an all-in-one control panel for this session — every toggle here runs beside the game.",
    Font = Enum.Font.Gotham,
    TextSize = 13,
    TextColor3 = T.textDim,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    ZIndex = 10,
    Parent = introCard,
})

local introRows = {
    { "Rebirth Farm", "Auto tower runs + 2-farm upgrade + rebirth." },
    { "Farm",         "Feeder upgrades, tower sends, strategy." },
    { "Fighting",     "Arena automation, chaos on full health." },
    { "Misc",         "Coop, recycler, incubator, eggs, fusing." },
    { "Server",       "Hops, rejoin, auto-load, auto-reconnect." },
}
for i, row in ipairs(introRows) do
    local y = 86 + (i - 1) * 26
    local wrapper = mk("Frame", {
        Size = UDim2.new(1, -48, 0, 20),
        Position = UDim2.new(0, 16, 0, y),
        BackgroundTransparency = 1,
        LayoutOrder = 10 + i,
        ZIndex = 10,
        Parent = introCard,
    })
    local dot = mk("Frame", {
        Size = UDim2.fromOffset(6, 6),
        Position = UDim2.new(0, 0, 0, 7),
        BackgroundColor3 = T.gold,
        BorderSizePixel = 0,
        ZIndex = 10,
        Parent = wrapper,
    })
    rounded(dot, 3)
    mk("TextLabel", {
        Size = UDim2.new(0, 118, 0, 20),
        Position = UDim2.new(0, 14, 0, 0),
        BackgroundTransparency = 1,
        Text = row[1],
        Font = Enum.Font.GothamBold,
        TextSize = 12.5,
        TextColor3 = T.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 10,
        Parent = wrapper,
    })
    mk("TextLabel", {
        Size = UDim2.new(1, -140, 0, 22),
        Position = UDim2.new(0, 132, 0, 0),
        BackgroundTransparency = 1,
        Text = row[2],
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextColor3 = T.textDim,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        ZIndex = 10,
        Parent = wrapper,
    })
end

mk("TextLabel", {
    Size = UDim2.new(1, -32, 0, 20),
    Position = UDim2.new(0, 16, 0, 214),
    BackgroundTransparency = 1,
    Text = "Tip: click the yellow  N  bubble to hide or show this window anytime.",
    Font = Enum.Font.Gotham,
    TextSize = 12,
    TextColor3 = T.goldLo,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 10,
    Parent = introCard,
})

-- on reload, tear down the previous run's window so windows don't stack.
-- Deliberately does NOT call killAllNexusWindows: that sweep is gen-aware, but
-- a live-reload from a pre-rejoin generation can fire its teardown late, after
-- a newer run has already rebuilt the window, and a non-gen-aware sweep here
-- would murder the brand-new window. Only our own objects are touched; the
-- next run's pre-build sweep handles any true leftovers.
if STATE then
    STATE.onCleanup(function()
        pcall(function() if sg then sg:Destroy() end end)
        pcall(function() if ultraOverlay then ultraOverlay:Destroy() end end)
        pcall(function() RunService:Set3dRenderingEnabled(true) end)
        if getgenv().NexusHubWin == sg then getgenv().NexusHubWin = nil end
    end)
end

-- toggle registration: { tab, section, name, flag, fn[, default] }
-- Rebirth Farm is ONE toggle: it drives the feeder loop, the auto tower
-- (frontier -> warm-up -> floor 1 fallback) and the retreat-rebirth cycle.
local toggles = {
    -- Rebirth Farm tab
    { "rfarm",  "Rebirth Farm","Auto Rebirth Farm",          "rebirthFarm",            runRebirthFarm },

    -- Farm tab
    { "farm",   "Farming",    "Auto Send Tower",            "sendTower",              runSendTower },
    { "farm",   "Farming",    "Auto Upgrade Feeder",        "upgradeFeeder",          runUpgradeFeeder },
    { "farm",   "Farming",    "Auto Buy Feeder",            "buyFeeder",              runBuyFeeder },
    { "farm",   "Farming",    "Auto Upgrade Coop",          "upgradeCoop",            runUpgradeCoop },
    { "farm",   "Farming",    "Auto Claim Egg Incubator",   "autoClaimEggIncubator",  runAutoClaimEggIncubator },
    { "farm",   "Farming",    "Auto Collect Eggs",         "autoCollectEggs",        runAutoCollectEggs },
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

-- Register every loop toggle onto its page, grouped under section headers.
local lastSection = {}
for _, t in ipairs(toggles) do
    local page = tabFrames[t[1]]
    if not page then continue end
    local section, name, flagKey, fn = t[2], t[3], t[4], t[5]
    if lastSection[t[1]] ~= section then
        addSection(page, section)
        lastSection[t[1]] = section
    end
    addToggle(page, name, flagKey, function(v)
        if v then spawnLoop(flagKey, fn) end
    end)
end
pcall(syncCanvas)

-- Auto Farm tower start strategy (Auto Send Tower uses this to pick the floor)
local strategyOptions = {
    "Straight To Your Frontier",
    "Warm Up At Floor",
    "Start From The Bottom",
}
addSection(tabFrames.farm, "Tower & Eggs")
local stratIndex = (flags.towerStrategy == "warmup" and 2)
    or (flags.towerStrategy == "bottom" and 3)
    or 1
addDropdown(tabFrames.farm, "Tower Strategy", strategyOptions, stratIndex, function(opt)
    if opt == "Warm Up At Floor" then
        flags.towerStrategy = "warmup"
    elseif opt == "Start From The Bottom" then
        flags.towerStrategy = "bottom"
    else
        flags.towerStrategy = "frontier"
    end
end)

-- Farm: how far to scan for world egg drops when Auto Collect Eggs is on
addSlider(tabFrames.farm, "Collect Egg Scan Radius", 30, 500, 10, " studs",
    flags.collectEggRadius or 200, function(v) flags.collectEggRadius = v end)
pcall(syncCanvas)

-- Misc / Utilities: the two performance toggles are immediate effects, not loops
addToggle(tabFrames.misc, "Performance Mode", "performance", function(v)
    applyPerformance(v)
end)
addToggle(tabFrames.misc, "Ultra Performance Mode", "ultraPerformance", function(v)
    applyUltraPerformance(v)
end)

-- Misc / Hub: unload everything
addSection(tabFrames.misc, "Hub")
addButton(tabFrames.misc, "Unload Nexus Hub", function()
    -- kill every loop (hubAlive gates on this) and reset all flags
    getgenv().NX_HUB = false
    for k in pairs(flags) do flags[k] = false end
    -- restore rendering + remove the black overlay if it was on
    pcall(function() RunService:Set3dRenderingEnabled(true) end)
    pcall(function() if ultraOverlay then ultraOverlay:Destroy() end end)
    -- destroy the GUI (and any leftover hub windows)
    pcall(function() if sg then sg:Destroy() end end)
    killAllNexusWindows(true)
    getgenv().NexusHubWin = nil
    getgenv().NX_HUB = nil
end)

-- Server tab: same-place server hopping + rejoin
addSection(tabFrames.server, "Server")
addButton(tabFrames.server, "Server Hop", function()
    serverHop()
end)
addButton(tabFrames.server, "Server Hop Low Players", function()
    serverHopLow()
end)
addButton(tabFrames.server, "Rejoin", function()
    rejoin()
end)
addToggle(tabFrames.server, "Auto Load on Teleport", "autoLoadOnTeleport", function(v)
    if v then task.spawn(runQueueKeepAlive) end
end)
addToggle(tabFrames.server, "Auto Reconnect (rejoin on kick / 20 min idle)", "autoReconnect", function(v)
    if v then task.spawn(runAutoReconnect) end
end)

-- land on the Home tab and reveal the window
pcall(function() switchTab("home") end)

-- apply any states already active this run (loops gate on these flags)
if flags.performance then applyPerformance(true) end
if flags.ultraPerformance then applyUltraPerformance(true) end
if flags.autoReconnect then task.spawn(runAutoReconnect) end
if flags.autoLoadOnTeleport then task.spawn(runQueueKeepAlive) end

getgenv().NX_HUB = true
