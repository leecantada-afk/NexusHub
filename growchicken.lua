--[[ NEXUS HUB — Grow a Chicken Fighter ]]
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
local Rayfield
if not getgenv().NexusRayfield then
    Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()
    getgenv().NexusRayfield = Rayfield
else
    Rayfield = getgenv().NexusRayfield
end

local inv = Remotes.invoke
local R = Remotes.defs
local GC = GameConfig.generators

local flags = {
    upgradeFeeder = false,
    sendTower = false,
    buyFeeder = false,
    hatchEggs = false,
    collectEggs = false,
    rebirth = false,
    antiAfk = false,
    performance = false,
    claimMissions = false,
    claimDaily = false,
    claimRebirth = false,
    claimSocial = false,
    autoRedeem = false,
    upgradeCoop = false,
    upgradeRecycler = false,
    declineTowerContinue = false,
    autoIncubator = false,
    autoArena = false,
    autoClaimPass = false,
    autoRebirthSetting = false,
    autoFuse = false,
    autoShopDust = false,
    autoSell = false,
    autoHotEgg = false,
}

-- Current known-good codes (refreshed from community trackers). The server validates
-- each one for us: invalid/expired/already-used codes just return an error, so trying
-- the whole list every cycle is safe and only the valid, unredeemed ones grant rewards.
local knownCodes = {
    "BATTLEREADY",
    "ASCEND",
    "50MVISITS",
    "EGGSCELLENT",
    "LETMECOOK",
    "SERGIOVERSE",
    "WELCOME",
}
local codes = {} -- optional extra codes added via the input box
local redeemed = {} -- dedupe map so each code only fires once

-- helpers ---------------------------------------------------------------
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

-- flat list of owned chickens (excluding eggs) with their ids
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

-- per-toggle loops ------------------------------------------------------
-- Auto Upgrade Feeder: raise every generator toward maxLevel, cheapest first
local function runUpgradeFeeder()
    while getgenv().NX_HUB and flags.upgradeFeeder do
        local c = coop()
        local gens = c.generators or {}
        local best, bestSlot, bestCost = 0, nil, nil
        for _, g in ipairs(gens) do
            if g.level and g.level < GC.maxLevel then
                local cost = math.floor(GC.upgradeCost.base * (GC.upgradeCost.growth ^ math.max(0, g.level - 1)))
                if bestSlot == nil or cost < bestCost then
                    best, bestCost, bestSlot = g.level, cost, g.slot
                end
            end
        end
        if bestSlot and money() >= (bestCost or 0) then
            pcallInvoke(R.UpgradeGenerator, bestSlot)
        end
        task.wait(0.8)
    end
end

-- Auto Send Tower: send when idle (full health)
local function runSendTower()
    while getgenv().NX_HUB and flags.sendTower do
        local v = vitals()
        if (v.health or 1) >= 0.999 then
            task.spawn(function() pcallInvoke(R.TowerStart) end)
            task.wait(2.5)
        end
        task.wait(0.7)
    end
end

-- Auto Buy Feeder: fill slots, expanding coop toward maxSlots when needed
local function runBuyFeeder()
    while getgenv().NX_HUB and flags.buyFeeder do
        local c = coop()
        local gens = c.generators or {}
        local slots = c.slots or #gens
        -- each generator owns a slot; first empty slot is next index
        local cur = #gens
        if cur < GC.maxSlots and cur >= slots then
            -- need to expand coop to open another slot
            local cost = math.floor(GC.expandCost.base * (GC.expandCost.growth ^ math.max(0, cur - GC.coopMinSize)))
            if money() >= cost then
                pcallInvoke(R.ExpandCoop)
                task.wait(1.5)
            end
        elseif cur < GC.maxSlots and cur < slots then
            local nextSlot = cur + 1
            local cost = math.floor(GC.buyCost.base * (GC.buyCost.growth ^ math.max(0, cur - 1)))
            if money() >= cost then
                pcallInvoke(R.BuyGenerator, nextSlot)
                task.wait(1.5)
            end
        end
        task.wait(1.0)
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
            -- only collect eggs owned by the local player (laid by their chicken in their coop)
            if egg:GetAttribute("owner") ~= Player.UserId then continue end
            local hrp = getCharRoot()
            if hrp and egg:IsA("BasePart") then
                local target = egg.Position
                local dist = (hrp.Position - target).Magnitude
                -- bring the character within ~4 studs
                local ok = pcall(function()
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

-- Auto Rebirth: rebirth when idle, at full health, AND at home so the server accepts it.
-- The server rejects rebirth unless the rooster is resting at the corral ("busyTower" /
-- "notAtCoop" errors), so we mirror the game's own gate: order=="coop" && where=="corral".
local function atCorral()
    return ChickenMode.order() == "coop" and ChickenMode.where() == "corral"
end

local function runRebirth()
    while getgenv().NX_HUB and flags.rebirth do
        local v = vitals()
        local best = towerBest()
        if atCorral() and best >= 1 and (v.health or 1) >= 0.999 then
            pcallInvoke(R.Rebirth)
            task.wait(3)
        end
        task.wait(1.0)
    end
end

-- Auto Upgrade Coop: expand capacity/slots toward maxSlots when affordable
local function runUpgradeCoop()
    while getgenv().NX_HUB and flags.upgradeCoop do
        local c = coop()
        local slots = c.slots or 0
        if slots < GC.maxSlots and CoopView.canExpand(slots) then
            local cost = CoopView.expandCost(slots) or 0
            if money() >= cost then
                pcallInvoke(R.ExpandCoop)
                task.wait(1.5)
            end
        end
        task.wait(1.0)
    end
end

-- Auto Upgrade Recycler: raise recycler while affordable and unlocked
local function runUpgradeRecycler()
    while getgenv().NX_HUB and flags.upgradeRecycler do
        local ok, scrap = pcall(function() return client:get({"scrap"}) end)
        local level = (ok and scrap and scrap.recyclerLevel) or 0
        local okR, rebirth = pcall(function() return client:get({"rebirth"}) end)
        local rbCount = (okR and type(rebirth) == "table" and rebirth.count) or 0
        local best = towerBest()
        if RecyclerView.canUpgrade(level, rbCount)
            and RecyclerView.floorUnlocked(level, best)
            and money() >= (RecyclerView.upgradeCost(level) or 0) then
            pcallInvoke(R.UpgradeRecycler)
            task.wait(1.5)
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

-- Auto Claim Missions: claim every mission whose progress meets target
local function missionStateData()
    local ok, rb = pcall(function() return client:get({"rebirth"}) end)
    local ok2, missions = pcall(function() return client:get({"missions"}) end)
    return {
        roster = roster(),
        towerBest = towerBest(),
        rebirthCount = (ok and type(rb) == "table" and rb.count) or 0,
        recyclerLevel = 0,
        missions = (ok2 and missions) or {},
    }
end

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

-- Auto Claim Daily streak + session day
local function runClaimDaily()
    while getgenv().NX_HUB and flags.claimDaily do
        local ok, daily = pcall(function() return client:get({"daily"}) end)
        if ok and daily then
            local claimed = daily.claimed or {}
            -- streak day
            if not claimed["day"] and not claimed["d"] then
                pcallInvoke(R.DailyClaim, "day", nil)
                task.wait(0.6)
            end
            -- session tiers (s1..s3)
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
        local okR, rebirth = pcall(function() return client:get({"rebirth"}) end)
        local rbCount = (okR and type(rebirth) == "table" and rebirth.count) or 0
        local lvl = inc.level or 0
        local can, need = IncubatorView.canUpgrade(lvl, rbCount)
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
                    if type(c) == "table" and c.id then
                        table.insert(sorted, c)
                    end
                end
                -- strongest first
                table.sort(sorted, function(a, b)
                    local ap = a.powerBig or 0
                    local bp = b.powerBig or 0
                    return ap > bp
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

-- Auto Rebirth setting: turn on the game's native auto-rebirth (needs the pass)
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

-- Auto Claim Pass: claim every claimable pass rung
local function runAutoClaimPass()
    while getgenv().NX_HUB and flags.autoClaimPass do
        local ok, purs = pcall(function() return client:get({"purchases"}) end)
        local passes = (ok and purs and purs.passes) or {}
        -- iterate the claimed pass map to find unclaimed rungs; the server
        -- rejects invalid/claimable-status calls harmlessly, so we attempt each
        for tier, rungs in pairs(passes) do
            if type(rungs) == "table" then
                for k, claimed in pairs(rungs) do
                    if claimed == false or claimed == nil then
                        if tonumber(k) then
                            pcallInvoke(R.PassClaim, tonumber(k), tier)
                            task.wait(0.8)
                        end
                    end
                end
            end
        end
        task.wait(6.0)
    end
end

-- Auto Fuse Chickens: fuse duplicates of the same typeId into a stronger one
local function runAutoFuse()
    while getgenv().NX_HUB and flags.autoFuse do
        local list = chickenList()
        -- group by typeId, keep only groups with 2+
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

-- Auto Claim Shop Dust: claim the daily shop dust reward
local function runAutoShopDust()
    while getgenv().NX_HUB and flags.autoShopDust do
        pcallInvoke(R.ClaimShopDust)
        task.wait(15.0)
    end
end

-- Auto Sell / Dupe cleanup: keep one chicken per typeId, sell the rest (low rarity first)
local function runAutoSell()
    while getgenv().NX_HUB and flags.autoSell do
        local list = chickenList()
        local activeId = roster().activeId
        local seen = {}
        local sell = {}
        for _, c in ipairs(list) do
            if c.id == activeId then
                seen[c.typeId] = true
            else
                if seen[c.typeId] then
                    table.insert(sell, c.id) -- duplicate -> sell
                else
                    seen[c.typeId] = true
                end
            end
        end
        if #sell > 0 then
            pcallInvoke(R.SellChickens, sell)
            task.wait(1.0)
        end
        task.wait(5.0)
    end
end

-- Auto Hot Egg: when you are the egg carrier, dodge meteors and fly to the safe zone
local function runAutoHotEgg()
    local meteors = {} -- {pos=Vector3, radius=number, hitAt=os.clock()+fall}
    local conns = {}

    -- telegrams are broadcast to all clients; we use them to dodge
    local m = Remotes.onClient(R.HotEggMeteor, function(p)
        if type(p) ~= "table" or typeof(p.at) ~= "Vector3" then return end
        local fall = tonumber(p.fall) or 1.6
        local radius = tonumber(p.radius) or 15
        table.insert(meteors, {
            pos = p.at,
            radius = radius,
            hitAt = os.clock() + fall,
        })
    end)
    local prune = RunService.Heartbeat:Connect(function()
        local now = os.clock()
        for i = #meteors, 1, -1 do
            if meteors[i].hitAt + 0.4 < now then
                table.remove(meteors, i)
            end
        end
    end)
    table.insert(conns, m)
    table.insert(conns, prune)

    local carried = false -- was carrier on the previous pass
    while getgenv().NX_HUB and flags.autoHotEgg do
        local egg = workspace:FindFirstChild("HotEgg")
        local hrp = getCharRoot()
        if egg and egg:IsA("BasePart") and hrp then
            local carrier = egg:GetAttribute("Carrier")
            local isCarrier = type(carrier) == "number" and carrier == Player.UserId
            local now = os.clock()

            if isCarrier then
                local pos = hrp.Position
                -- dodge horizontally out of any meteor that is about to land near us
                local move = Vector3.new(0, 0, 0)
                for _, met in ipairs(meteors) do
                    if met.hitAt > now and met.hitAt - now < 3 then
                        local d = met.pos - pos
                        local flat = Vector3.new(d.X, 0, d.Z)
                        local len = flat.Magnitude
                        local threat = met.radius + 2
                        if len < threat then
                            if len > 0.001 then
                                move = move + (-flat / len) * (threat - len + 1)
                            else
                                move = move + Vector3.new(1, 0, 0) * (threat + 1)
                            end
                        end
                    end
                end
                -- fly up just a LITTLE and only once when we first grab the egg, then stay.
                -- no continuous climbing / holding - that looks like flying and can get kicked.
                local hopY = 0
                if not carried and pos.Y < 4 then
                    hopY = math.min(6 - pos.Y, 6)
                end
                local newPos = pos + move + Vector3.new(0, hopY, 0)
                local delta = newPos - pos
                if delta.Magnitude > 0.3 then
                    hrp.CFrame = hrp.CFrame + delta
                end
                carried = true
            else
                -- not carrying: close the distance to grab the egg (pickupRadius ~5)
                local d = egg.Position - hrp.Position
                d = Vector3.new(d.X, 0, d.Z)
                local len = d.Magnitude
                if len > 0.1 then
                    hrp.CFrame = hrp.CFrame + (d / len) * 30
                end
                carried = false
            end
        end
        task.wait()
    end

    for _, c in ipairs(conns) do
        pcall(function() c:Disconnect() end)
    end
end

-- Auto Redeem Codes: automatically claim every known code currently available.
-- The server validates each attempt (invalid/used/expired just return an error), so
-- trying the full list is safe; only codes that actually grant a reward count.
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
            if state.ok then
                redeemed[code] = true -- claimed successfully, don't retry
            elseif state.error == "used" or state.error == "depleted" then
                redeemed[code] = true -- already claimed before, don't retry
            elseif state.error == "unknown" or state.error == "early" or state.error == "expired" then
                redeemed[code] = true -- not claimable, don't retry
            end
            task.wait(1.0)
            -- stop if toggled off while redeeming
            if not (getgenv().NX_HUB and flags.autoRedeem) then break end
        end
        -- refresh in case new codes become available
        refreshPool()
        task.wait(20.0)
    end
end

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

-- spawn/stop a loop helper
local function toggleStart(name, fn, flag)
    flag.value = not flag.value
    getgenv().NX_HUB = true
    if flag.value then
        task.spawn(fn)
    end
end

-- build UI --------------------------------------------------------------
local win = Rayfield:CreateWindow({
    Name = "NEXUS HUB",
    Subtitle = "Grow a Chicken Fighter",
    LoadingTitle = "NEXUS HUB",
    LoadingSubtitle = "by Real",
    ConfigurationSaving = { Enabled = true, FolderName = "NexusHub", FileName = "settings" },
    Discord = { Enabled = false },
    KeySystem = false,
    ToggleUIKeybind = Enum.KeyCode.RightAlt,
})

-- on reload, tear down the previous run's window so windows don't stack
if STATE then
    STATE.onCleanup(function()
        pcall(function() if win then win:Unload() end end)
    end)
end

local farm = win:CreateTab({ Name = "Farm", Icon = "home" })
local misc = win:CreateTab({ Name = "Misc", Icon = "settings" })
local eventsTab = win:CreateTab({ Name = "Events", Icon = "star" })
local progTab = win:CreateTab({ Name = "Progression", Icon = "rocket" })

farm:CreateSection({ Name = "Farming" })

farm:CreateToggle({
    Name = "Auto Upgrade Feeder",
    Default = false,
    Callback = function(v) flags.upgradeFeeder = v; if v then task.spawn(runUpgradeFeeder) end end,
})

farm:CreateToggle({
    Name = "Auto Buy Feeder",
    Default = false,
    Callback = function(v) flags.buyFeeder = v; if v then task.spawn(runBuyFeeder) end end,
})

farm:CreateToggle({
    Name = "Auto Send Tower",
    Default = false,
    Callback = function(v) flags.sendTower = v; if v then task.spawn(runSendTower) end end,
})

farm:CreateToggle({
    Name = "Auto Hatch Eggs",
    Default = false,
    Callback = function(v) flags.hatchEggs = v; if v then task.spawn(runHatchEggs) end end,
})

farm:CreateToggle({
    Name = "Auto Collect Eggs",
    Default = false,
    Callback = function(v) flags.collectEggs = v; if v then task.spawn(runCollectEggs) end end,
})

farm:CreateToggle({
    Name = "Auto Rebirth",
    Default = false,
    Callback = function(v) flags.rebirth = v; if v then task.spawn(runRebirth) end end,
})

farm:CreateToggle({
    Name = "Auto Upgrade Coop",
    Default = false,
    Callback = function(v) flags.upgradeCoop = v; if v then task.spawn(runUpgradeCoop) end end,
})

farm:CreateToggle({
    Name = "Auto Upgrade Recycler",
    Default = false,
    Callback = function(v) flags.upgradeRecycler = v; if v then task.spawn(runUpgradeRecycler) end end,
})

farm:CreateToggle({
    Name = "Auto Decline Tower Continue",
    Default = false,
    Callback = function(v) flags.declineTowerContinue = v; if v then task.spawn(runDeclineTowerContinue) end end,
})

-- Note: "Auto Open Gifts" is the daily reward claim -> see "Auto Claim Daily" below

eventsTab:CreateSection({ Name = "Live Events" })

eventsTab:CreateToggle({
    Name = "Auto Hot Egg (dodge)",
    Default = false,
    Callback = function(v) flags.autoHotEgg = v; if v then task.spawn(runAutoHotEgg) end end,
})

misc:CreateSection({ Name = "Claims" })

misc:CreateToggle({
    Name = "Auto Claim Missions",
    Default = false,
    Callback = function(v) flags.claimMissions = v; if v then task.spawn(runClaimMissions) end end,
})

misc:CreateToggle({
    Name = "Auto Claim Daily",
    Default = false,
    Callback = function(v) flags.claimDaily = v; if v then task.spawn(runClaimDaily) end end,
})

misc:CreateToggle({
    Name = "Auto Claim Rebirth Milestones",
    Default = false,
    Callback = function(v) flags.claimRebirth = v; if v then task.spawn(runClaimRebirth) end end,
})

misc:CreateToggle({
    Name = "Auto Claim Social",
    Default = false,
    Callback = function(v) flags.claimSocial = v; if v then task.spawn(runClaimSocial) end end,
})

progTab:CreateSection({ Name = "Progression" })

progTab:CreateToggle({
    Name = "Auto Incubator",
    Default = false,
    Callback = function(v) flags.autoIncubator = v; if v then task.spawn(runAutoIncubator) end end,
})

progTab:CreateToggle({
    Name = "Auto Arena / Pit",
    Default = false,
    Callback = function(v) flags.autoArena = v; if v then task.spawn(runAutoArena) end end,
})

progTab:CreateToggle({
    Name = "Auto Fuse Chickens",
    Default = false,
    Callback = function(v) flags.autoFuse = v; if v then task.spawn(runAutoFuse) end end,
})

progTab:CreateToggle({
    Name = "Auto Sell Duplicates",
    Default = false,
    Callback = function(v) flags.autoSell = v; if v then task.spawn(runAutoSell) end end,
})

misc:CreateSection({ Name = "Utility" })

misc:CreateToggle({
    Name = "Anti AFK",
    Default = false,
    Callback = function(v) flags.antiAfk = v; if v then task.spawn(runAntiAfk) end end,
})

misc:CreateSection({ Name = "Economy" })

misc:CreateToggle({
    Name = "Auto Claim Pass",
    Default = false,
    Callback = function(v) flags.autoClaimPass = v; if v then task.spawn(runAutoClaimPass) end end,
})

misc:CreateToggle({
    Name = "Auto Rebirth Setting (native)",
    Default = false,
    Callback = function(v) flags.autoRebirthSetting = v; if v then task.spawn(runAutoRebirthSetting) end end,
})

misc:CreateToggle({
    Name = "Auto Claim Shop Dust",
    Default = false,
    Callback = function(v) flags.autoShopDust = v; if v then task.spawn(runAutoShopDust) end end,
})

misc:CreateSection({ Name = "Codes" })

misc:CreateToggle({
    Name = "Auto Redeem All Codes",
    Default = false,
    Callback = function(v) flags.autoRedeem = v; if v then task.spawn(runRedeem) end end,
})

misc:CreateInput({
    Name = "Extra Code",
    PlaceholderText = "optional extra code",
    RemoveTextAfterFocusLost = true,
    Callback = function(v)
        if v and v ~= "" then
            local code = string.gsub(string.upper(v), "%s+", "")
            table.insert(codes, code)
        end
    end,
})

misc:CreateToggle({
    Name = "Performance Mode",
    Default = false,
    Callback = function(v) flags.performance = v; applyPerformance(v) end,
})

getgenv().NX_HUB = true
