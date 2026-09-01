--[[ ============================================================
     NEXUS HUB — Grow a Chicken Fighter
     Organized: helpers -> loops (by category) -> UI build
     ============================================================ ]]

------------------------------------------------------------------
-- Services & requires
------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

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

-- Rayfield is shared globally so re-runs don't stack windows
local Rayfield = getgenv().NexusRayfield
if not Rayfield then
    Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()
    getgenv().NexusRayfield = Rayfield
end

local inv = Remotes.invoke
local R = Remotes.defs
local GC = GameConfig.generators

------------------------------------------------------------------
-- Config
------------------------------------------------------------------
local flags = {
    upgradeFeeder = false,
    buyFeeder = false,
    sendTower = false,
    hatchEggs = false,
    collectEggs = false,
    rebirth = false,
    declineTowerContinue = false,
    upgradeCoop = false,
    upgradeRecycler = false,
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
    autoClaimPass = false,
    autoRebirthSetting = false,
    autoShopDust = false,
    autoRedeem = false,
    antiAfk = false,
    autoHotEgg = false,
    performance = false,
}

-- Global hot egg state — set while egg is live so runSendTower pauses
local hotEggActive = false

local PIT_RADIUS = 40

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

------------------------------------------------------------------
-- FARM loops
------------------------------------------------------------------

-- Auto Upgrade Feeder: raise every generator toward maxLevel, cheapest first
local function runUpgradeFeeder()
    while getgenv().NX_HUB and flags.upgradeFeeder do
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
    while getgenv().NX_HUB and flags.buyFeeder do
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

-- Auto Send Tower: send when idle (full health) — but not while a hot egg is live
local function runSendTower()
    while getgenv().NX_HUB and flags.sendTower do
        local v = vitals()
        if (v.health or 1) >= 0.999 and not hotEggActive then
            task.spawn(function() pcallInvoke(R.TowerStart) end)
            task.wait(2.5)
        end
        task.wait(0.7)
    end
end

-- Auto Hatch Eggs: hatch every egg in inventory
local function runHatchEggs()
    while getgenv().NX_HUB and flags.hatchEggs do
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

-- Auto Collect Eggs: only collect YOUR OWN chicken's eggs laid inside your coop
local function runCollectEggs()
    while getgenv().NX_HUB and flags.collectEggs do
        local eggs = CollectionService:GetTagged("NestEgg")
        for _, egg in ipairs(eggs) do
            if not getgenv().NX_HUB or not flags.collectEggs then break end
            if egg:GetAttribute("owner") ~= Player.UserId then continue end
            local hrp = getCharRoot()
            if hrp and egg:IsA("BasePart") then
                local target = egg.Position
                -- bring the character within ~4 studs
                pcall(function()
                    local bv = Instance.new("BodyVelocity")
                    bv.MaxForce = Vector3.new(1e6, 1e6, 1e6)
                    bv.Velocity = (target - hrp.Position).Unit * 40
                    bv.Parent = hrp
                    task.wait(0.6)
                    bv:Destroy()
                end)
                -- click the egg with a native click
                pcall(function()
                    local cam = workspace.CurrentCamera
                    if cam then
                        local sp, on = cam:WorldToScreenPoint(target)
                        if on then mousemoveabs(sp.X, sp.Y) end
                    end
                    task.wait(0.15)
                    mouse1click()
                end)
                task.wait(0.8)
            end
        end
        task.wait(2.0)
    end
end

-- Auto Rebirth: rebuild when idle, at full health, and resting at the corral
local function runRebirth()
    while getgenv().NX_HUB and flags.rebirth do
        local v = vitals()
        if atCorral() and towerBest() >= 1 and (v.health or 1) >= 0.999 then
            pcallInvoke(R.Rebirth)
            task.wait(3)
        end
        task.wait(1.0)
    end
end

-- Auto Decline Tower Continue: hit "no thanks" when the continue offer appears
local continueConn = nil
local function runDeclineTowerContinue()
    while getgenv().NX_HUB and flags.declineTowerContinue do
        if not continueConn then
            continueConn = Remotes.onClient(R.TowerContinueOffer, function()
                task.spawn(function()
                    pcall(Remotes.fire, R.TowerContinueDecline)
                end)
            end)
        end
        task.wait(1)
    end
    if continueConn then
        pcall(function() continueConn:Disconnect() end)
        continueConn = nil
    end
end

------------------------------------------------------------------
-- PROGRESSION loops
------------------------------------------------------------------

-- Auto Upgrade Coop: expand capacity/slots toward maxSlots when affordable
local function runUpgradeCoop()
    while getgenv().NX_HUB and flags.upgradeCoop do
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
    while getgenv().NX_HUB and flags.upgradeRecycler do
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
    while getgenv().NX_HUB and flags.autoIncubator do
        local inc = incubatorData()
        local eggs = inc.eggs or {}

        -- claim ready hatched eggs
        if #eggs > 0 then
            pcallInvoke(R.IncubatorClaim)
            task.wait(1.0)
        end

        -- insert / swap the best chicken into the incubator when idle
        local idle = (inc.progress or 0) <= 0 and #eggs == 0 and inc.level >= 0
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
    while getgenv().NX_HUB and flags.autoClaimEggIncubator do
        if #(incubatorData().eggs or {}) > 0 then
            pcallInvoke(R.IncubatorClaim)
            task.wait(1.0)
        end
        task.wait(5.0)
    end
end

-- Auto Upgrade Incubator: raise the incubator level (no claim / tenant)
local function runAutoUpgradeIncubator()
    while getgenv().NX_HUB and flags.autoUpgradeIncubator do
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
    while getgenv().NX_HUB and flags.autoFuse do
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
    while getgenv().NX_HUB and flags.autoSell do
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
    while getgenv().NX_HUB and flags.autoArena do
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
    return {
        roster = roster(),
        towerBest = towerBest(),
        rebirthCount = rebirthCount(),
        recyclerLevel = 0,
        missions = (ok2 and missions) or {},
    }
end

-- Auto Claim Missions: claim every mission whose progress meets the target
local function runClaimMissions()
    while getgenv().NX_HUB and flags.claimMissions do
        local md = missionStateData()
        for _, scope in ipairs(MissionView.SCOPES) do
            local act, aerr = pcall(MissionView.active, scope)
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
    while getgenv().NX_HUB and flags.claimDaily do
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
    while getgenv().NX_HUB and flags.claimRebirth do
        pcallInvoke(R.ClaimRebirthMilestones)
        task.wait(6.0)
    end
end

-- Auto Claim Social / Community reward
local function runClaimSocial()
    while getgenv().NX_HUB and flags.claimSocial do
        pcallInvoke(R.SocialClaim)
        task.wait(10.0)
    end
end

-- Auto Claim Pass: claim every claimable pass rung
local function runAutoClaimPass()
    while getgenv().NX_HUB and flags.autoClaimPass do
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
    while getgenv().NX_HUB and flags.autoShopDust do
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
    while getgenv().NX_HUB and flags.autoRedeem do
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
            if not (getgenv().NX_HUB and flags.autoRedeem) then break end
        end
        refreshPool()
        task.wait(20.0)
    end
end

-- Auto Rebirth Setting: turn on the game's native auto-rebirth (needs the pass)
local function runAutoRebirthSetting()
    while getgenv().NX_HUB and flags.autoRebirthSetting do
        local ok, reb = pcall(function() return client:get({"rebirth"}) end)
        local auto = ok and type(reb) == "table" and reb.auto == true
        if not auto then
            pcallInvoke(R.SetAutoRebirth, true)
        end
        task.wait(8.0)
    end
end

------------------------------------------------------------------
-- MOVEMENT / UTILITY loops
------------------------------------------------------------------

-- Anti AFK: periodic movement
local function runAntiAfk()
    local last = 0
    while getgenv().NX_HUB and flags.antiAfk do
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

-- Auto Hot Egg: when Workspace.HotEgg appears while farming, stop tower
-- temporarily, route the character to the egg (jumping the pit fence at
-- the ring edge), and resume farming once the egg is grabbed or gone.
local function runAutoHotEgg()
    while getgenv().NX_HUB and flags.autoHotEgg do
        local egg = workspace:FindFirstChild("HotEgg")
        if egg and egg:IsA("BasePart") then
            hotEggActive = true
            local hrp = getCharRoot()
            local hum = hrp and hrp.Parent and hrp.Parent:FindFirstChildOfClass("Humanoid")
            if hrp and hum then
                local eggPos = egg.Position
                local toEgg = eggPos - hrp.Position
                local hDist = Vector3.new(toEgg.X, 0, toEgg.Z).Magnitude
                local originDist = Vector3.new(hrp.Position.X, 0, hrp.Position.Z).Magnitude

                if hDist > 5 then
                    -- push the character horizontally toward the egg
                    local bv = Instance.new("BodyVelocity")
                    bv.MaxForce = Vector3.new(1e6, 0, 1e6)
                    bv.Velocity = Vector3.new(toEgg.X, 0, toEgg.Z).Unit * 50
                    bv.Parent = hrp
                    -- jump over the pit fence when in the ring-edge zone
                    if originDist > (PIT_RADIUS - 4) and originDist < (PIT_RADIUS + 4) then
                        pcall(function() hum.Jump = true end)
                    end
                    task.wait(0.25)
                    pcall(function() bv:Destroy() end)
                end
            end
        else
            if hotEggActive then hotEggActive = false end
        end
        task.wait(0.15)
    end
    hotEggActive = false
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
    ConfigurationSaving = { Enabled = true, FolderName = "NexusHub", FileName = "settings" },
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
    -- Farm
    { "farm",   "Farming",    "Auto Upgrade Feeder",        "upgradeFeeder",          runUpgradeFeeder },
    { "farm",   "Farming",    "Auto Buy Feeder",            "buyFeeder",              runBuyFeeder },
    { "farm",   "Farming",    "Auto Send Tower",            "sendTower",              runSendTower },
    { "farm",   "Farming",    "Auto Hatch Eggs",            "hatchEggs",              runHatchEggs },
    { "farm",   "Farming",    "Auto Collect Eggs",          "collectEggs",            runCollectEggs },
    { "farm",   "Farming",    "Auto Rebirth",               "rebirth",                runRebirth },
    { "farm",   "Farming",    "Auto Upgrade Coop",          "upgradeCoop",            runUpgradeCoop },
    { "farm",   "Farming",    "Auto Upgrade Recycler",      "upgradeRecycler",        runUpgradeRecycler },
    { "farm",   "Farming",    "Auto Decline Tower Continue","declineTowerContinue",   runDeclineTowerContinue },

    -- Progression
    { "prog",   "Progression","Auto Incubator",             "autoIncubator",          runAutoIncubator },
    { "prog",   "Progression","Auto Claim Egg Incubator",   "autoClaimEggIncubator",  runAutoClaimEggIncubator },
    { "prog",   "Progression","Auto Upgrade Incubator",     "autoUpgradeIncubator",   runAutoUpgradeIncubator },
    { "prog",   "Progression","Auto Arena / Pit",           "autoArena",              runAutoArena },
    { "prog",   "Progression","Auto Fuse Chickens",         "autoFuse",               runAutoFuse },
    { "prog",   "Progression","Auto Sell Duplicates",       "autoSell",               runAutoSell },

    -- Events
    { "events", "World Events","Auto Hot Egg (Jump Fence)", "autoHotEgg",             runAutoHotEgg },

    -- Misc / Claims
    { "misc",   "Claims",     "Auto Claim Missions",        "claimMissions",          runClaimMissions },
    { "misc",   "Claims",     "Auto Claim Daily",           "claimDaily",             runClaimDaily },
    { "misc",   "Claims",     "Auto Claim Rebirth Milestones","claimRebirth",         runClaimRebirth },
    { "misc",   "Claims",     "Auto Claim Social",          "claimSocial",            runClaimSocial },

    -- Misc / Utility
    { "misc",   "Utility",    "Anti AFK",                   "antiAfk",                runAntiAfk },

    -- Misc / Economy
    { "misc",   "Economy",    "Auto Claim Pass",            "autoClaimPass",          runAutoClaimPass },
    { "misc",   "Economy",    "Auto Rebirth Setting (native)","autoRebirthSetting",   runAutoRebirthSetting },
    { "misc",   "Economy",    "Auto Claim Shop Dust",       "autoShopDust",           runAutoShopDust },

    -- Misc / Codes
    { "misc",   "Codes",      "Auto Redeem All Codes",      "autoRedeem",             runRedeem },
}

local tabs = {
    farm = win:CreateTab({ Name = "Farm", Icon = "home" }),
    misc = win:CreateTab({ Name = "Misc", Icon = "settings" }),
    events = win:CreateTab({ Name = "Events", Icon = "star" }),
    prog = win:CreateTab({ Name = "Progression", Icon = "rocket" }),
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
        Default = false,
        Callback = function(v)
            flags[flagKey] = v
            if v then task.spawn(fn) end
        end,
    })
end

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
    Default = false,
    Callback = function(v) flags.performance = v; applyPerformance(v) end,
})

getgenv().NX_HUB = true
