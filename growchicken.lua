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
-- Config
------------------------------------------------------------------
local flags = {
    upgradeFeeder = false,
    buyFeeder = false,
    sendTower = false,
    hatchEggs = false,
    rebirth = false,
    rebirthFarm = false, -- beta: one toggle = auto tower + 2-farm upgrade + retreat-rebirth
    -- tower strategy: "frontier" | "warmup" | "bottom"
    towerStrategy = "frontier",
    upgradeCoop = false,
    upgradeRecycler = false,
    collectEggs = false,
    autoIncubator = false,
    autoClaimEggIncubator = false,
    autoUpgradeIncubator = false,
    autoFuse = false,
    autoSell = false,
    autoArena = false,
    claimMissions = false,
    claimDaily = false,
    claimRebirth = false,
    claimSocial = false,
    autoPet = false,
    autoClaimPass = false,
    autoShopDust = false,
    autoRedeem = false,
    antiAfk = false,
    performance = false,
    autoLoadOnTeleport = false,
    autoReconnect = false,
}

-- Current known-good codes (server validates each; only valid, unredeemed grant rewards)
local knownCodes = {
    "BATTLEREADY",
    "ASCEND",
    "50MVISITS",
    "EGGSCELLENT",
    "LETMECOOK",
    "SERGIOVERSE",
    "WELCOME",
}
local codes = {}   -- optional extra codes added via the input box
local redeemed = {} -- dedupe map so each code only fires once

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
local reconnectConn = nil
local function runAutoReconnect()
    if reconnectConn then
        pcall(function() reconnectConn:Disconnect() end)
        reconnectConn = nil
    end
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
    reconnectConn = nil
end

------------------------------------------------------------------
-- FARM loops
------------------------------------------------------------------

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
            pcallInvoke(R.UpgradeGenerator, bestSlot)
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
                pcallInvoke(R.ExpandCoop)
                task.wait(1.5)
            end
        elseif cur < GC.maxSlots and cur < slots then
            local cost = math.floor(GC.buyCost.base * (GC.buyCost.growth ^ math.max(0, cur - 1)))
            if money() >= cost then
                pcallInvoke(R.BuyGenerator, cur + 1)
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
        if (v.health or 1) >= 0.999 and not (flags.rebirth and rebirthReady()) then
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

-- Auto Hatch Eggs: hatch every egg in inventory
local function runHatchEggs()
    while hubAlive() and flags.hatchEggs do
        local r = roster()
        if r.eggs then
            for eggId, count in pairs(r.eggs) do
                if count and count > 0 then
                    pcallInvoke(R.HatchEggs, eggId, count)
                    task.wait(0.5)
                end
            end
        end
        task.wait(2.0)
    end
end

-- Noclip: temporarily disable the home coop's fences and the character's own
-- collision so the chicken can walk through them to reach eggs pressed against
-- the walls. Restores nothing persistently — the fence parts are static and the
-- server owns their CanCollide; we only flip it while Auto Collect Eggs is on.
local function coopFloorOf(model)
    local fl = model and model:FindFirstChild("Floor")
    if not fl then return nil end
    return fl.Position, (fl.Size.X or 30) / 2
end

-- The player's own coop: the coop currently containing the character's root
-- (falls back to the coop containing the active chicken).
local function homeCoop()
    local hrp = getCharRoot()
    local c = game:GetService("Workspace"):FindFirstChild("Coops")
    if c then
        for _, m in ipairs(c:GetChildren()) do
            if m.Name ~= "CoopUI" and m.Name ~= "NeighborCoop" then
                local cx, half = coopFloorOf(m)
                if cx and hrp and math.abs(hrp.Position.X - cx.X) < half
                    and math.abs(hrp.Position.Z - cx.Z) < half then
                    return m
                end
            end
        end
    end
    return nil
end

-- All NestEgg parts sitting inside the given coop's floor bounds.
local function coopEggs(coop)
    local cx, half = coopFloorOf(coop)
    if not cx then return {} end
    local out = {}
    local nest = game:GetService("Workspace"):FindFirstChild("NestEggs")
    if nest then
        for _, e in ipairs(nest:GetChildren()) do
            if e:IsA("BasePart")
                and math.abs(e.Position.X - cx.X) < half
                and math.abs(e.Position.Z - cx.Z) < half then
                table.insert(out, e)
            end
        end
    end
    return out
end

-- Auto Collect Eggs: walk the chicken onto each egg inside the player's own
-- coop. Collection is character-touch based, so we make the coop fences
-- passable (CanCollide=false) plus noclip the character, walk to each egg, and
-- wait for it to disappear before moving to the next.
local function setNoclip(char, on)
    if not char then return end
    for _, p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") then pcall(function() p.CanCollide = not on end) end
    end
end

local function runCollectEggs()
    local coop = homeCoop()
    local prevCC = {} -- for restoring collidables
    while hubAlive() and flags.collectEggs do
        if not coop then coop = homeCoop() end
        if coop then
            -- remember original CanCollide on coop fences + chicken body, then disable
            for _, v in ipairs(coop:GetDescendants()) do
                if v:IsA("BasePart") and v.Name ~= "Floor" then
                    table.insert(prevCC, { part = v, was = v.CanCollide })
                    pcall(function() v.CanCollide = false end)
                end
            end
            -- also disable the coop's ChickenBody hitbox
            local coopNum = coop.Name:match("%d+")
            if coopNum then
                local cb = game:GetService("Workspace"):FindFirstChild("ChickenBodies")
                    and game:GetService("Workspace").ChickenBodies:FindFirstChild("ChickenBody_coop:" .. coopNum)
                if cb and cb:IsA("BasePart") then
                    table.insert(prevCC, { part = cb, was = cb.CanCollide })
                    pcall(function() cb.CanCollide = false end)
                end
            end
            -- full-character noclip (all BaseParts, not just HumanoidRootPart)
            local char = Player.Character
            setNoclip(char, true)

            local eggs = coopEggs(coop)
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if #eggs > 0 and hum and hrp then
                for _, egg in ipairs(eggs) do
                    if not (hubAlive() and flags.collectEggs) then break end
                    local target = egg.Position
                    hum:MoveTo(target)
                    local waited = 0
                    while waited < 15000 do
                        task.wait(0.4)
                        waited = waited + 400
                        if hrp and (hrp.Position - target).Magnitude > 1.5 then
                            pcall(function() hum:MoveTo(target) end)
                        end
                        if not egg.Parent then break end          -- collected / despawned
                        if not (hubAlive() and flags.collectEggs) then break end
                    end
                    task.wait(0.5)
                end
            end
            -- restore all collidables
            for _, entry in ipairs(prevCC) do
                if entry.part and entry.part.Parent then
                    pcall(function() entry.part.CanCollide = entry.was end)
                end
            end
            prevCC = {}
            setNoclip(char, false)
        end
        task.wait(3.0)
    end
end

-- Auto Rebirth: when rebirth is on and the requirement is met, actively
-- surrender any running tower so the chicken retreats to the corral, then
-- rebuild once it's home and back to full health. No more waiting for the
-- tower to lose before coming back.
local function runRebirth()
    while hubAlive() and flags.rebirth do
        if rebirthReady() and not atCorral() then
            -- chicken is away on a tower run / campaign: pull it back now
            pcallInvoke(R.TowerSurrender)
            task.wait(1.0)
        end
        local v = vitals()
        if atCorral() and towerBest() >= 1 and (v.health or 1) >= 0.999 then
            pcallInvoke(R.Rebirth)
            task.wait(3)
        end
        task.wait(0.7)
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
    while hubAlive() and flags.rebirthFarm do
        -- 1) retreat + rebirth once the threshold is met
        if rebirthReady() and not atCorral() then
            pcallInvoke(R.TowerSurrender)
            task.wait(1.0)
        end
        local v = vitals()
        if rebirthReady() and atCorral() and towerBest() >= 1 and (v.health or 1) >= 0.999 then
            pcallInvoke(R.Rebirth)
            task.wait(3)
        end
        -- 2) auto farm tower (never when rebirth is about to fire)
        if not rebirthReady() and (vitals().health or 1) >= 0.999 then
            task.spawn(function() pcallInvoke(R.TowerStart, towerStartFloor()) end)
            task.wait(2.5)
        end
        -- 3) make sure we have exactly 2 feeders: buy up to 2 (never a 3rd,
        --    never expand the coop). Then upgrade only the first two farms,
        --    cheapest of the two first.
        local c = coop()
        local gens = c.generators or {}
        local slots = c.slots or #gens
        local cur = #gens
        if cur < 2 and cur < slots then
            -- a free slot exists (no expansion needed) -> buy the next feeder
            local cost = math.floor(GC.buyCost.base * (GC.buyCost.growth ^ math.max(0, cur - 1)))
            if money() >= cost then
                pcallInvoke(R.BuyGenerator, cur + 1)
                task.wait(1.5)
            end
        end
        local bestSlot, bestCost = nil, nil
        for i = 1, math.min(2, #gens) do
            local g = gens[i]
            if g and g.level and g.level < GC.maxLevel then
                local cost = math.floor(GC.upgradeCost.base * (GC.upgradeCost.growth ^ math.max(0, g.level - 1)))
                if bestSlot == nil or cost < bestCost then
                    bestCost, bestSlot = cost, g.slot
                end
            end
        end
        if bestSlot and money() >= (bestCost or 0) then
            pcallInvoke(R.UpgradeGenerator, bestSlot)
        end
        task.wait(0.7)
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
                pcallInvoke(R.ExpandCoop)
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

-- Auto Incubator: claim hatched eggs, incubate your best chicken, upgrade level
local function runAutoIncubator()
    local lastInserted = nil
    while hubAlive() and flags.autoIncubator do
        local inc = incubatorData()
        local eggs = inc.eggs or {}

        -- claim ready hatched eggs
        if #eggs > 0 then
            pcallInvoke(R.IncubatorClaim)
            task.wait(1.0)
        end

        -- insert / swap the best chicken into the incubator when idle
        local idle = (inc.progress or 0) <= 0 and #eggs == 0
        if idle then
            local list = chickenList()
            local best
            for _, c in ipairs(list) do
                if not best or (c.level or 1) > (best.level or 1) then best = c end
            end
            if best and best.id ~= lastInserted then
                pcallInvoke(R.IncubatorRemove) -- clear any current tenant before swapping
                task.wait(0.3)
                pcallInvoke(R.IncubatorInsert, best.id)
                lastInserted = best.id
                task.wait(1.5)
            end
        end

        -- upgrade incubator level when affordable and rebirth is met
        local lvl = inc.level or 0
        local can = IncubatorView.canUpgrade(lvl, rebirthCount())
        if can and lvl < IncubatorView.maxLevel then
            local cost = IncubatorView.upgradeCost(lvl + 1) or 0
            if money() >= cost then
                pcallInvoke(R.IncubatorUpgrade)
                task.wait(1.5)
            end
        end
        task.wait(2.0)
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

-- Auto Claim Social / Community reward
local function runClaimSocial()
    while hubAlive() and flags.claimSocial do
        pcallInvoke(R.SocialClaim)
        task.wait(10.0)
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

-- Auto Redeem Codes: claim every known code that is currently valid,
-- plus any extra codes typed into the input box.
local function runRedeem()
    local pool = {}
    local function refreshPool()
        pool = {}
        for _, c in ipairs(knownCodes) do
            if not redeemed[c] then table.insert(pool, c) end
        end
        for _, c in ipairs(codes) do
            if not redeemed[c] then table.insert(pool, c) end
        end
    end
    refreshPool()
    while hubAlive() and flags.autoRedeem do
        for i = #pool, 1, -1 do
            local code = pool[i]
            local ok, res = pcall(inv, R.RedeemCode, code)
            local state = ok and type(res) == "table" and res or { ok = false }
            if state.ok
                or state.error == "used"
                or state.error == "depleted"
                or state.error == "unknown"
                or state.error == "early"
                or state.error == "expired" then
                redeemed[code] = true -- claimed or permanently unclaimable
            end
            task.wait(1.0)
            if not (hubAlive() and flags.autoRedeem) then break end
        end
        refreshPool()
        task.wait(20.0)
    end
end

------------------------------------------------------------------
-- MOVEMENT / UTILITY loops
------------------------------------------------------------------

-- Anti AFK: periodic movement
local function runAntiAfk()
    local last = 0
    while hubAlive() and flags.antiAfk do
        local now = tick()
        if now - last >= 60 then
            last = now
            local hrp = getCharRoot()
            if hrp then
                local hum = Player.Character and Player.Character:FindFirstChildOfClass("Humanoid")
                if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
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

-- Performance Mode
local function applyPerformance(on)
    pcall(function() RunService:Set3dRenderingEnabled(not on) end)
    if on then
        pcall(function() Lighting.GlobalShadows = false end)
        pcall(function() Lighting.Brightness = 1 end)
    else
        pcall(function() Lighting.GlobalShadows = true end)
    end
end

------------------------------------------------------------------
-- UI build
------------------------------------------------------------------
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

-- on reload, tear down the previous run's window so windows don't stack
if STATE then
    STATE.onCleanup(function()
        pcall(function() if win then win:Unload() end end)
    end)
end

-- toggle registration: { tab, section, name, flag, fn[, default] }
local toggles = {
    -- Rebirth farm (beta): one toggle controls tower farm + 2-farm upgrade + retreat-rebirth
    { "rfarm",  "Rebirth Farm","Auto Rebirth Farm",          "rebirthFarm",            runRebirthFarm },

    -- Farm
    { "farm",   "Farming",    "Auto Upgrade Feeder",        "upgradeFeeder",          runUpgradeFeeder },
    { "farm",   "Farming",    "Auto Buy Feeder",            "buyFeeder",              runBuyFeeder },
    { "farm",   "Farming",    "Auto Send Tower",            "sendTower",              runSendTower },
    { "farm",   "Farming",    "Auto Hatch Eggs",            "hatchEggs",              runHatchEggs },
    { "farm",   "Farming",    "Auto Collect Eggs",          "collectEggs",            runCollectEggs },
    { "farm",   "Farming",    "Auto Rebirth",               "rebirth",                runRebirth },
    { "farm",   "Farming",    "Auto Upgrade Coop",          "upgradeCoop",            runUpgradeCoop },
    { "farm",   "Farming",    "Auto Upgrade Recycler",      "upgradeRecycler",        runUpgradeRecycler },

    -- Progression
    { "prog",   "Progression","Auto Incubator",             "autoIncubator",          runAutoIncubator },
    { "prog",   "Progression","Auto Claim Egg Incubator",   "autoClaimEggIncubator",  runAutoClaimEggIncubator },
    { "prog",   "Progression","Auto Upgrade Incubator",     "autoUpgradeIncubator",   runAutoUpgradeIncubator },
    { "prog",   "Progression","Auto Arena / Pit",           "autoArena",              runAutoArena },
    { "prog",   "Progression","Auto Fuse Chickens",         "autoFuse",               runAutoFuse },
    { "prog",   "Progression","Auto Sell Duplicates",       "autoSell",               runAutoSell },

    -- Misc / Claims
    { "misc",   "Claims",     "Auto Claim Missions",        "claimMissions",          runClaimMissions },
    { "misc",   "Claims",     "Auto Claim Daily",           "claimDaily",             runClaimDaily },
    { "misc",   "Claims",     "Auto Claim Rebirth Milestones","claimRebirth",         runClaimRebirth },
    { "misc",   "Claims",     "Auto Claim Social",          "claimSocial",            runClaimSocial },

    -- Misc / Utility
    { "misc",   "Utility",    "Anti AFK",                   "antiAfk",                runAntiAfk },
    { "misc",   "Utility",    "Auto Pet",                   "autoPet",                runAutoPet },

    -- Misc / Economy
    { "misc",   "Economy",    "Auto Claim Pass",            "autoClaimPass",          runAutoClaimPass },
    { "misc",   "Economy",    "Auto Claim Shop Dust",       "autoShopDust",           runAutoShopDust },

    -- Misc / Codes
    { "misc",   "Codes",      "Auto Redeem All Codes",      "autoRedeem",             runRedeem },
}

local tabs = {
    rfarm = win:CreateTab({ Name = "Rebirth farm", Icon = "flame" }),
    farm = win:CreateTab({ Name = "Farm", Icon = "home" }),
    misc = win:CreateTab({ Name = "Misc", Icon = "settings" }),
    prog = win:CreateTab({ Name = "Progression", Icon = "rocket" }),
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
            if v then task.spawn(fn) end
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

-- Misc / Codes input box (not a toggle)
tabs.misc:CreateInput({
    Name = "Extra Code",
    PlaceholderText = "optional extra code",
    RemoveTextAfterFocusLost = true,
    Callback = function(v)
        if v and v ~= "" then
            table.insert(codes, string.gsub(string.upper(v), "%s+", ""))
        end
    end,
})

-- Performance Mode toggle (immediate, not a loop)
tabs.misc:CreateToggle({
    Name = "Performance Mode",
    Default = flags.performance == true,
    Callback = function(v)
        flags.performance = v
        applyPerformance(v)
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
        -- destroy the GUI
        pcall(function() if win then win:Unload() end end)
        getgenv().NX_HUB = nil
    end,
})

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
    end,
})
tabs.server:CreateToggle({
    Name = "Auto Reconnect (rejoin on kick)",
    Default = flags.autoReconnect == true,
    Callback = function(v)
        flags.autoReconnect = v
        if v then task.spawn(runAutoReconnect) end
    end,
})

-- apply any states already active this run (loops gate on these flags)
if flags.performance then applyPerformance(true) end
if flags.autoReconnect then task.spawn(runAutoReconnect) end

getgenv().NX_HUB = true
