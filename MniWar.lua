local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local VirtualUser = game:GetService("VirtualUser")
local TeleportService = game:GetService("TeleportService")

local LocalPlayer = Players.LocalPlayer

local genv = getgenv()
genv.__nexusVersion = (genv.__nexusVersion or 0) + 1
local MY_VERSION = genv.__nexusVersion
local function isCurrentVersion()
    return genv.__nexusVersion == MY_VERSION
end

local GetBridge = require(ReplicatedStorage.util.GetBridge)
local GetSignal = require(ReplicatedStorage.util.GetSignal)
local ClientData = require(ReplicatedStorage.client.modules.ClientData)
local ShopsConfig = require(ReplicatedStorage.shared.config.ShopsConfig)
local CraftingConfig = require(ReplicatedStorage.shared.config.CraftingConfig)
local GarnisonConfig = require(ReplicatedStorage.shared.config.GarnisonConfig)
local ResourcesConfig = require(ReplicatedStorage.shared.config.ResourcesConfig)
local getSkillsData = require(ReplicatedStorage.util.getSkillsData)

local SendTroopsToPoint = GetBridge("SendTroopsToPoint")
local SendRocketsToPoint = GetBridge("SendRocketsToPoint")
local UnclaimBase = GetBridge("UnclaimBase")
local BuyFromShop = GetBridge("BuyFromShop")
local BuyFromBlackMarketShop = GetBridge("BuyFromBlackMarketShop")
local CraftingStartCraft = GetBridge("CraftingStartCraft")
local CraftingClaimCraft = GetBridge("CraftingClaimCraft")
local UpdateFlags = GetBridge("UpdateFlags")
local SellAll = GetBridge("SellAll")
local CollectResourcesBridge = GetBridge("CollectResources")
local CollectBPPickup = GetBridge("CollectBPPickup")

local STATE = {
    threads = {},
    connections = {},
}

local CFG = {
    attackEnabled = false,
    attackBases = {},
    attackArmy = 1,
    attackDelay = 5,
    switchDelay = 3,
    waitConquered = true,
    raidEnabled = false,
    raidBases = {},
    raidPriority = true,
    raidEventEnabled = false,
    raidEventBases = {},
    raidEventArmy = 1,
    raidEventDelay = 5,
    unclaimEnabled = false,
    unclaimBases = {},
    autoBuyEnabled = false,
    autoBuyAll = false,
    buyDelay = 2,
    buyHouses = {},
    buyFarms = {},
    buyBlackMarket = {},
    buyMilitary = {},
    buyDecor = {},

    autoCraftEnabled = false,
    craftRecipes = {},
    weatherEvents = {},
    autoClaimBP = false,
    autoClaimAll = false,
    autoRejoin = false,
    sameServer = false,
    antiAfk = false,
    disableNotifs = false,
    blockPopups = false,
    cullDistance = 500,
    lowPerf = false,
    removeFog = false,
    blackScreen = false,
    disable3D = false,
    antiLag = false,
    hideOtherPlots = false,
    cullEnabled = false,
    menuBind = "LeftControl",
    autoSellEnabled = false,
    autoSellThreshold = 150,
    autoCollectFarms = false,
    collectFarmDelay = 10,
    autoCollectBP = false,
}

local function killThread(name)
    if STATE.threads[name] then
        task.cancel(STATE.threads[name])
        STATE.threads[name] = nil
    end
end

local ALL_CP_TAGS = {
    "CapturePoint",
    "CapturePointKingOfTheHill",
    "CapturePointToxicKingOfTheHill",
    "CapturePointAlienKingOfTheHill",
}

local function findCP(name)
    for _, tag in ALL_CP_TAGS do
        for _, cp in CollectionService:GetTagged(tag) do
            if cp and cp.Parent and cp:IsDescendantOf(Workspace) and cp.Name == name then
                return cp
            end
        end
    end
    return nil
end

local function isOwned(cp)
    return cp:GetAttribute("Owner") == LocalPlayer.Name
end

local function getAllCPNames()
    local seen = {}
    local names = {}
    for _, tag in ALL_CP_TAGS do
        for _, cp in CollectionService:GetTagged(tag) do
            if cp and cp.Parent and cp:IsDescendantOf(Workspace) then
                if not seen[cp.Name] then
                    seen[cp.Name] = true
                    table.insert(names, cp.Name)
                end
            end
        end
    end
    table.sort(names)
    return names
end

local function getShopItems(category)
    local items = {}
    local shop = ShopsConfig[category]
    if shop then
        for _, item in shop do
            table.insert(items, item.name)
        end
    end
    table.sort(items)
    return items
end

local function getCraftingRecipes()
    local recipes = {}
    if CraftingConfig.Recipes then
        for _, r in CraftingConfig.Recipes do
            table.insert(recipes, r.displayName or r.id)
        end
    end
    table.sort(recipes)
    return recipes
end

local function getRecipeById(displayName)
    if CraftingConfig.Recipes then
        for _, r in CraftingConfig.Recipes do
            if r.displayName == displayName then
                return r
            end
        end
    end
    return nil
end

local function waitConquered(cp, timeout)
    timeout = timeout or 120
    local start = tick()
    if isOwned(cp) then return true end
    local conn
    conn = cp:GetAttributeChangedSignal("Owner"):Connect(function()
        if isOwned(cp) then
            if conn then conn:Disconnect() end
        end
    end)
    while not isOwned(cp) and (tick() - start) < timeout do
        task.wait(1)
    end
    if conn then pcall(function() conn:Disconnect() end) end
    return isOwned(cp)
end

local WEATHER_EVENTS = {
    { id = "Storm",            label = "Storm",            baseTypes = {},                                tag = "CapturePoint" },
    { id = "NuclearFallout",   label = "Nuclear Fallout",  baseTypes = {"RaidBase"},                      tag = "CapturePoint" },
    { id = "BeastBreach",      label = "Beast Breach",     baseTypes = {"MechBeast"},                      tag = "CapturePoint" },
    { id = "RobotUprising",    label = "Robot Uprising",   baseTypes = {"RobotBase"},                      tag = "CapturePoint" },
    { id = "Rebellion",        label = "Rebellion",        baseTypes = {"RaidBase"},                       tag = "CapturePoint" },
    { id = "OverStockCargoStorm", label = "Cargo Storm",  baseTypes = {"CargoBase"},                      tag = "CapturePoint" },
    { id = "Invasion",         label = "Invasion",         baseTypes = {},                                 tag = "CapturePoint" },
    { id = "HackerOverride",   label = "Hacker Override",  baseTypes = {"HackerBase"},                     tag = "CapturePoint" },
    { id = "AlienInvasion",    label = "Alien Invasion",   baseTypes = {"AlienKingOfTheHill", "AlienInvasionBase"}, tag = "CapturePoint" },
    { id = "MeteorShower",     label = "Meteor Shower",    baseTypes = {"MeteorBase"},                     tag = "CapturePoint" },
}

local RAID_EVENTS = {
    { id = "KingOfTheHill",    label = "King Of The Hill",      tag = "CapturePointKingOfTheHill",  baseType = "KingOfTheHill" },
    { id = "ToxicKingOfTheHill", label = "Toxic King Of The Hill", tag = "CapturePointToxicKingOfTheHill", baseType = "ToxicKingOfTheHill" },
}

local REJOIN_LOADER = "NexusHub/rejoin_loader.luau"

local function queueRejoinExec()
    pcall(function()
        local loader = readfile(REJOIN_LOADER)
        if loader then
            queue_on_teleport(loader)
        end
    end)
end

local function saveRejoinLoader()
    pcall(function()
        writefile(REJOIN_LOADER, [[loadstring(readfile("NexusHub/nexus_hub.luau"))()]])
    end)
end

local function buyItem(item, shop)
    if shop == "BlackMarket" then
        pcall(function() BuyFromBlackMarketShop:Fire({ shop = "BlackMarket", item = item }) end)
    else
        pcall(function() BuyFromShop:Fire({ shop = shop, item = item }) end)
    end
end

local function buyAllFromCategory(category, shop)
    local items = getShopItems(category)
    for _, item in items do
        buyItem(item, shop)
        task.wait(CFG.buyDelay)
    end
end

local function startAttackLoop()
    STATE.threads.attack = task.spawn(function()
        while isCurrentVersion() and CFG.attackEnabled do
            local bases = CFG.attackBases
            if #bases > 0 then
                for _, baseName in bases do
                    if not CFG.attackEnabled then break end
                    local cp = findCP(baseName)
                    if cp and not isOwned(cp) then
                        pcall(function() SendTroopsToPoint:Fire({ armyIndex = CFG.attackArmy, capturePoint = cp }) end)
                        if CFG.waitConquered then waitConquered(cp, 120) else task.wait(CFG.switchDelay) end
                    end
                end
            end
            task.wait(CFG.attackDelay)
        end
    end)
end

local function startRaidLoop()
    STATE.threads.raid = task.spawn(function()
        while isCurrentVersion() and CFG.raidEnabled do
            local selectedEvents = CFG.weatherEvents
            if #selectedEvents > 0 then
                local activeBaseTypes = {}
                for _, label in selectedEvents do
                    for _, ev in WEATHER_EVENTS do
                        if ev.label == label then
                            for _, bt in ev.baseTypes do
                                activeBaseTypes[bt] = true
                            end
                        end
                    end
                end
                if next(activeBaseTypes) then
                    for _, tag in ALL_CP_TAGS do
                        for _, cp in CollectionService:GetTagged(tag) do
                            if not CFG.raidEnabled then break end
                            if cp and cp.Parent and cp:IsDescendantOf(Workspace) then
                                local bt = cp:GetAttribute("baseType")
                                if bt and activeBaseTypes[bt] and not isOwned(cp) then
                                    pcall(function() SendTroopsToPoint:Fire({ armyIndex = CFG.attackArmy, capturePoint = cp }) end)
                                    if CFG.waitConquered then waitConquered(cp, 120) else task.wait(CFG.switchDelay) end
                                end
                            end
                        end
                    end
                end
            end
            task.wait(CFG.attackDelay)
        end
    end)
end

local function startRaidEventLoop()
    STATE.threads.raidEvent = task.spawn(function()
        while isCurrentVersion() and CFG.raidEventEnabled do
            local selectedLabels = CFG.raidEventBases
            if #selectedLabels > 0 then
                local activeTags = {}
                for _, label in selectedLabels do
                    for _, ev in RAID_EVENTS do
                        if ev.label == label then
                            activeTags[ev.tag] = true
                        end
                    end
                end
                if next(activeTags) then
                    for _, ev in RAID_EVENTS do
                        if not CFG.raidEventEnabled then break end
                        if activeTags[ev.tag] then
                            for _, cp in CollectionService:GetTagged(ev.tag) do
                                if not CFG.raidEventEnabled then break end
                                if cp and cp.Parent and cp:IsDescendantOf(Workspace) then
                                    if not isOwned(cp) then
                                        pcall(function() SendTroopsToPoint:Fire({ armyIndex = CFG.raidEventArmy, capturePoint = cp }) end)
                                        if CFG.waitConquered then waitConquered(cp, 120) else task.wait(CFG.switchDelay) end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            task.wait(CFG.raidEventDelay)
        end
    end)
end

local function startUnclaimLoop()
    STATE.threads.unclaim = task.spawn(function()
        while isCurrentVersion() and CFG.unclaimEnabled do
            local bases = CFG.unclaimBases
            if #bases > 0 then
                for _, label in bases do
                    if not CFG.unclaimEnabled then break end
                    for _, tag in ALL_CP_TAGS do
                        for _, cp in CollectionService:GetTagged(tag) do
                            if cp and cp.Parent and cp:IsDescendantOf(Workspace) then
                                local baseType = cp:GetAttribute("baseType") or "Unknown"
                                local cfg = GarnisonConfig[baseType]
                                local displayName = (cfg and cfg.displayName) or baseType
                                local parentFolder = cp.Parent and cp.Parent.Name or ""
                                local cpLabel = displayName .. " (" .. parentFolder .. "/" .. cp.Name .. ")"
                                if cpLabel == label and isOwned(cp) then
                                    pcall(function() UnclaimBase:Fire(cp) end)
                                    task.wait(2)
                                end
                            end
                        end
                    end
                end
            end
            task.wait(5)
        end
    end)
end

local function startBuySelectedLoop()
    STATE.threads.buySelected = task.spawn(function()
        while isCurrentVersion() and CFG.autoBuyEnabled do
            for _, item in CFG.buyHouses do buyItem(item, "House") task.wait(CFG.buyDelay) end
            for _, item in CFG.buyFarms do buyItem(item, "Farm") task.wait(CFG.buyDelay) end
            for _, item in CFG.buyBlackMarket do buyItem(item, "BlackMarket") task.wait(CFG.buyDelay) end
            for _, item in CFG.buyMilitary do buyItem(item, "Military") task.wait(CFG.buyDelay) end
            for _, item in CFG.buyDecor do buyItem(item, "Decor") task.wait(CFG.buyDelay) end

            task.wait(CFG.buyDelay)
        end
    end)
end

local function startBuyAllLoop()
    STATE.threads.buyAll = task.spawn(function()
        while isCurrentVersion() and CFG.autoBuyAll do
            buyAllFromCategory("House", "House")
            buyAllFromCategory("Farm", "Farm")
            buyAllFromCategory("BlackMarket", "BlackMarket")
            buyAllFromCategory("Military", "Military")
            buyAllFromCategory("Decor", "Decor")
            task.wait(CFG.buyDelay)
        end
    end)
end

local function startCraftLoop()
    STATE.threads.craft = task.spawn(function()
        while isCurrentVersion() and CFG.autoCraftEnabled do
            pcall(function()
                local craftingData = ClientData.playerProducer:getState().player.craftingData
                if craftingData and craftingData.slots then
                    local now = math.floor(workspace:GetServerTimeNow())
                    local maxSlots = 6
                    for i = 1, maxSlots do
                        local slot = craftingData.slots[i] or craftingData.slots[tostring(i)]
                        if slot and slot.finishesAt and slot.finishesAt <= now then
                            CraftingClaimCraft:Fire({ slotIndex = i })
                            task.wait(0.5)
                        end
                    end
                end
            end)
            local recipes = CFG.craftRecipes
            if #recipes > 0 then
                for _, displayName in recipes do
                    if not CFG.autoCraftEnabled then break end
                    local recipe = getRecipeById(displayName)
                    if recipe then
                        pcall(function() CraftingStartCraft:Fire({ recipeId = recipe.id }) end)
                        task.wait(CFG.buyDelay)
                    end
                end
            end
            task.wait(10)
        end
    end)
end

local function startAntiAfkLoop()
    STATE.threads.antiAfk = task.spawn(function()
        while isCurrentVersion() and CFG.antiAfk do
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:Button2Down(Vector2.new(0, 0), Workspace.CurrentCamera.CFrame)
                task.wait(0.1)
                VirtualUser:Button2Up(Vector2.new(0, 0), Workspace.CurrentCamera.CFrame)
            end)
            task.wait(30)
        end
    end)
end

local function startClaimBPLoop()
    STATE.threads.claimBP = task.spawn(function()
        while isCurrentVersion() and CFG.autoClaimBP do
            for stage = 1, 50 do
                if not CFG.autoClaimBP then break end
                pcall(function() GetBridge("ClaimBPReward"):Fire({track = "Free", stage = stage}) end)
                task.wait(0.1)
                pcall(function() GetBridge("ClaimBPReward"):Fire({track = "Premium", stage = stage}) end)
                task.wait(0.1)
            end
            task.wait(60)
        end
    end)
end

local function startClaimAllLoop()
    STATE.threads.claimAll = task.spawn(function()
        while isCurrentVersion() and CFG.autoClaimAll do
            pcall(function() GetBridge("DailyRewardsClaim"):Fire() end)
            task.wait(2)
            pcall(function() GetBridge("ClaimReturningDailyReward"):Fire() end)
            task.wait(2)
            pcall(function() GetBridge("ClaimLikeReward"):Fire() end)
            task.wait(2)
            for stage = 1, 50 do
                if not CFG.autoClaimAll then break end
                pcall(function() GetBridge("ClaimBPReward"):Fire({track = "Free", stage = stage}) end)
                task.wait(0.1)
                pcall(function() GetBridge("ClaimBPReward"):Fire({track = "Premium", stage = stage}) end)
                task.wait(0.1)
            end
            task.wait(60)
        end
    end)
end

local function startRejoin()
    saveRejoinLoader()
    queueRejoinExec()
    STATE.connections.rejoinTeleport = LocalPlayer.OnTeleport:Connect(function(ts)
        if ts == Enum.TeleportState.Started then CFG.autoRejoin = false end
    end)
    STATE.threads.rejoinDetect = task.spawn(function()
        while isCurrentVersion() and CFG.autoRejoin do
            if not LocalPlayer.Character or not LocalPlayer.Character:FindFirstChild("Humanoid") then
                task.wait(3)
                if not LocalPlayer.Character or not LocalPlayer.Character:FindFirstChild("Humanoid") then
                    pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
                    task.wait(5)
                end
            end
            task.wait(1)
        end
    end)
end

local function startCullLoop()
    STATE.threads.cull = task.spawn(function()
        while isCurrentVersion() and CFG.cullEnabled do
            pcall(function()
                local char = LocalPlayer.Character
                local hrp = char and char:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local pos = hrp.Position
                    for _, model in Workspace:GetDescendants() do
                        if model:IsA("Model") and model ~= char then
                            local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
                            if primary then
                                local dist = (primary.Position - pos).Magnitude
                                if dist > CFG.cullDistance then
                                    for _, part in model:GetDescendants() do
                                        if part:IsA("BasePart") then
                                            part.LocalTransparencyModifier = 1
                                        end
                                    end
                                else
                                    for _, part in model:GetDescendants() do
                                        if part:IsA("BasePart") then
                                            part.LocalTransparencyModifier = 0
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end)
            task.wait(0.5)
        end
    end)
end

local function startHidePlotsLoop()
    STATE.threads.hidePlots = task.spawn(function()
        while isCurrentVersion() and CFG.hideOtherPlots do
            pcall(function()
                local myTag = LocalPlayer.Name .. "-Plot"
                for _, tag in CollectionService:GetTags() do
                    if tag:match("-Plot$") and tag ~= myTag then
                        for _, obj in CollectionService:GetTagged(tag) do
                            if obj:IsA("Model") or obj:IsA("Folder") then
                                obj.DescendantAdded = nil
                                for _, d in obj:GetDescendants() do
                                    if d:IsA("BasePart") then
                                        d.LocalTransparencyModifier = 1
                                    end
                                end
                            end
                        end
                    end
                end
            end)
            task.wait(2)
        end
    end)
end

local function startNotifBlock()
    STATE.threads.notifBlock = task.spawn(function()
        while isCurrentVersion() and CFG.disableNotifs do
            pcall(function()
                for _, gui in LocalPlayer.PlayerGui:GetDescendants() do
                    if gui:IsA("Frame") and gui.Name:lower():find("notif") then
                        gui.Visible = false
                    end
                end
            end)
            task.wait(1)
        end
    end)
end

local function startPopupBlock()
    STATE.threads.popupBlock = task.spawn(function()
        while isCurrentVersion() and CFG.blockPopups do
            pcall(function()
                local oldUI = LocalPlayer.PlayerGui:FindFirstChild("OldUI")
                if oldUI then
                    local warnUI = oldUI:FindFirstChild("WarningUI")
                    if warnUI then warnUI.Enabled = false end
                    local notifyUI = oldUI:FindFirstChild("NotifyUI")
                    if notifyUI then notifyUI.Enabled = false end
                    local tradeUI = oldUI:FindFirstChild("TradeRequestUI")
                    if tradeUI then tradeUI.Enabled = false end
                end
            end)
            task.wait(1)
        end
    end)
end

local function getMarketStockPercent()
    local total = 0
    local count = 0
    pcall(function()
        local state = ClientData.gameProducer:getState()
        local stock = state.market and state.market.stock or {}
        local nuclear = state.nuclearMarketBoosts or {}
        local skills = getSkillsData(LocalPlayer)
        local skillBonus = (skills.marketPrice or 0) / 100
        for name, cfg in ResourcesConfig do
            if not cfg.dontDisplayInMarket then
                local s = (stock[name] or 1) + (nuclear[name] or 0) + skillBonus
                total = total + s * 100
                count = count + 1
            end
        end
    end)
    if count > 0 then return total / count end
    return 100
end

local function startAutoSellLoop()
    STATE.threads.autoSell = task.spawn(function()
        while isCurrentVersion() and CFG.autoSellEnabled do
            pcall(function()
                local avg = getMarketStockPercent()
                if avg >= CFG.autoSellThreshold then
                    SellAll:Fire()
                end
            end)
            task.wait(5)
        end
    end)
end

local function startAutoCollectFarmsLoop()
    STATE.threads.collectFarms = task.spawn(function()
        while isCurrentVersion() and CFG.autoCollectFarms do
            pcall(function()
                local GetPlotModel = require(ReplicatedStorage.util.GetPlotModel)
                local plot = GetPlotModel(LocalPlayer)
                if plot then
                    local plotFolder = plot:FindFirstChild("Plot")
                    local buildings = plotFolder and plotFolder:FindFirstChild("Buildings")
                    if buildings then
                        for _, b in buildings:GetChildren() do
                            if not CFG.autoCollectFarms then break end
                            local btype = b:GetAttribute("type")
                            if btype == "Farm" or btype == "GemMine" or btype == "CloneFacility" then
                                local amount = b:GetAttribute("ResourcesToCollect") or 0
                                if amount > 0 then
                                    CollectResourcesBridge:Fire(b)
                                end
                            end
                        end
                    end
                end
            end)
            task.wait(CFG.collectFarmDelay)
        end
    end)
end

local function startAutoCollectBPLoop()
    STATE.threads.collectBP = task.spawn(function()
        while isCurrentVersion() and CFG.autoCollectBP do
            pcall(function()
                for _, obj in Workspace:GetDescendants() do
                    if not CFG.autoCollectBP then break end
                    if obj.Name == "BATTLEPASS_POINT_PICKUP" and obj.Parent then
                        CollectBPPickup:Fire(obj)
                        task.wait(0.5)
                    end
                end
            end)
            task.wait(2)
        end
    end)
end

local KEY_MAP = {
    ["LeftControl"] = Enum.KeyCode.LeftControl,
    ["RightControl"] = Enum.KeyCode.RightControl,
    ["LeftShift"] = Enum.KeyCode.LeftShift,
    ["RightShift"] = Enum.KeyCode.RightShift,
    ["LeftAlt"] = Enum.KeyCode.LeftAlt,
    ["RightAlt"] = Enum.KeyCode.RightAlt,
    ["Tab"] = Enum.KeyCode.Tab,
    ["Q"] = Enum.KeyCode.Q,
    ["E"] = Enum.KeyCode.E,
    ["R"] = Enum.KeyCode.R,
    ["T"] = Enum.KeyCode.T,
    ["Y"] = Enum.KeyCode.Y,
    ["U"] = Enum.KeyCode.U,
    ["I"] = Enum.KeyCode.I,
    ["O"] = Enum.KeyCode.O,
    ["P"] = Enum.KeyCode.P,
    ["F1"] = Enum.KeyCode.F1,
    ["F2"] = Enum.KeyCode.F2,
    ["F3"] = Enum.KeyCode.F3,
    ["F4"] = Enum.KeyCode.F4,
    ["F5"] = Enum.KeyCode.F5,
    ["F6"] = Enum.KeyCode.F6,
    ["F7"] = Enum.KeyCode.F7,
    ["F8"] = Enum.KeyCode.F8,
    ["F9"] = Enum.KeyCode.F9,
    ["F10"] = Enum.KeyCode.F10,
    ["F11"] = Enum.KeyCode.F11,
    ["F12"] = Enum.KeyCode.F12,
}
local KEY_NAMES = {}
for k, _ in KEY_MAP do table.insert(KEY_NAMES, k) end
table.sort(KEY_NAMES)

local CONFIG_DIR = "NexusHub"
local CONFIGS_DIR = CONFIG_DIR .. "/configs"
local AUTOLoad_FILE = CONFIG_DIR .. "/autoload.txt"
local AUTOSAVE_FILE = CONFIGS_DIR .. "/_autosave.json"
local _cfgLoading = false
local _autoSavePending = false

pcall(function()
    if not isfolder(CONFIG_DIR) then makefolder(CONFIG_DIR) end
    if not isfolder(CONFIGS_DIR) then makefolder(CONFIGS_DIR) end
end)

local function autoSave()
    if _cfgLoading then return end
    if _autoSavePending then return end
    _autoSavePending = true
    task.delay(0.5, function()
        _autoSavePending = false
        pcall(function()
            writefile(AUTOSAVE_FILE, HttpService:JSONEncode(CFG))
        end)
    end)
end

local function autoLoad()
    _cfgLoading = true
    pcall(function()
        local raw = readfile(AUTOSAVE_FILE)
        if raw and raw ~= "" then
            local data = HttpService:JSONDecode(raw)
            for k, v in pairs(data) do
                if CFG[k] ~= nil then
                    CFG[k] = v
                end
            end
        end
    end)
    _cfgLoading = false
end

autoLoad()

task.spawn(function()
    while true do
        task.wait(2)
        autoSave()
    end
end)

local function getConfigNames()
    local names = {}
    pcall(function()
        local files = listfiles(CONFIGS_DIR)
        for _, f in files do
            if f:match("%.json$") then
                local name = f:gsub("%.json$", ""):match("([^/\\]+)$") or f:gsub("%.json$", "")
                table.insert(names, name)
            end
        end
    end)
    return names
end

local function saveConfig(name)
    local ok, err = pcall(function()
        writefile(CONFIGS_DIR .. "/" .. name .. ".json", HttpService:JSONEncode(CFG))
    end)
    if not ok then
        warn("[Nexus] saveConfig error:", err)
    end
end

local function loadConfig(name)
    local ok, err = pcall(function()
        local raw = readfile(CONFIGS_DIR .. "/" .. name .. ".json")
        local data = HttpService:JSONDecode(raw)
        for k, v in pairs(data) do
            if CFG[k] ~= nil then
                CFG[k] = v
            end
        end
    end)
    if not ok then
        warn("[Nexus] loadConfig error:", err)
    end
end

local function applyConfig()
    killThread("attack"); killThread("raid"); killThread("raidEvent"); killThread("unclaim")
    killThread("buySelected"); killThread("buyAll"); killThread("craft")
    killThread("claimBP"); killThread("claimAll"); killThread("antiAfk")
    killThread("rejoinDetect"); killThread("notifBlock")
    killThread("popupBlock"); killThread("hidePlots"); killThread("cull")
    killThread("autoSell"); killThread("collectFarms"); killThread("collectBP")

    if STATE.connections.rejoinTeleport then
        pcall(function() STATE.connections.rejoinTeleport:Disconnect() end)
        STATE.connections.rejoinTeleport = nil
    end

    task.wait(0.5)

    if CFG.attackEnabled then startAttackLoop() end
    if CFG.raidEnabled then startRaidLoop() end
    if CFG.raidEventEnabled then startRaidEventLoop() end
    if CFG.unclaimEnabled then startUnclaimLoop() end
    if CFG.autoBuyEnabled then startBuySelectedLoop() end
    if CFG.autoBuyAll then startBuyAllLoop() end
    if CFG.autoCraftEnabled then startCraftLoop() end
    if CFG.autoClaimBP then startClaimBPLoop() end
    if CFG.autoClaimAll then startClaimAllLoop() end
    if CFG.antiAfk then startAntiAfkLoop() end
    if CFG.autoRejoin then startRejoin() end
    if CFG.cullEnabled then startCullLoop() end
    if CFG.disableNotifs then startNotifBlock() end
    if CFG.blockPopups then startPopupBlock() end
    if CFG.hideOtherPlots then startHidePlotsLoop() end
    if CFG.autoSellEnabled then startAutoSellLoop() end
    if CFG.autoCollectFarms then startAutoCollectFarmsLoop() end
    if CFG.autoCollectBP then startAutoCollectBPLoop() end
    autoSave()
end

local function deleteConfig(name)
    pcall(function()
        delfile(CONFIGS_DIR .. "/" .. name .. ".json")
    end)
end

local function setAutoLoad(name)
    pcall(function()
        writefile(AUTOLoad_FILE, name)
    end)
end

local function getAutoLoad()
    local ok, name = pcall(function()
        return readfile(AUTOLoad_FILE)
    end)
    return ok and name or nil
end

local function resetAutoLoad()
    pcall(function()
        delfile(AUTOLoad_FILE)
    end)
end

local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Window = WindUI:CreateWindow({
    Title = "Nexus HUB",
    Icon = "zap",
    Author = "Mini War",
    Folder = CONFIG_DIR,
    Size = UDim2.fromOffset(620, 480),
    MinSize = Vector2.new(580, 400),
    MaxSize = Vector2.new(800, 600),
    Theme = "Dark",
    ToggleKey = KEY_MAP[CFG.menuBind] or Enum.KeyCode.LeftControl,
    Resizable = true,
    HideSearchBar = true,
    AutoScale = true,
    IgnoreAlerts = true,
})

local UI_REFS = {}

local AttackTab = Window:Tab({
    Title = "Attack",
    Icon = "swords",
})

AttackTab:Section({
    Title = "⚔ Auto Attack Bases",
    Icon = "crosshair",
})

local baseNames = getAllCPNames()

AttackTab:Dropdown({
    Title = "Select Bases to Attack",
    Desc = "Pick multiple military bases",
    Values = baseNames,
    Multi = true,
    AllowNone = true,
    Callback = function(sel)
        CFG.attackBases = sel or {}
    end,
})

UI_REFS.attackArmy = AttackTab:Dropdown({
    Title = "Army Slot",
    Values = {"1", "2", "3", "4", "5"},
    Value = "1",
    Callback = function(sel)
        CFG.attackArmy = tonumber(sel) or 1
    end,
})

UI_REFS.attackEnabled = AttackTab:Toggle({
    Title = "Enable Auto Attack",
    Value = false,
    Callback = function(state)
        CFG.attackEnabled = state
        if state then startAttackLoop() else killThread("attack") end
    end,
})

UI_REFS.waitConquered = AttackTab:Toggle({
    Title = "Wait Until Conquered",
    Desc = "Only switch to next base after current one is captured",
    Value = true,
    Callback = function(state)
        CFG.waitConquered = state
    end,
})

UI_REFS.attackDelay = AttackTab:Slider({
    Title = "Attack Delay (sec)",
    Desc = "Delay between full attack cycles",
    Value = { Min = 1, Max = 60, Default = 5 },
    Callback = function(v)
        CFG.attackDelay = v
    end,
})

UI_REFS.switchDelay = AttackTab:Slider({
    Title = "Switch Delay (sec)",
    Desc = "Delay between bases (if not waiting for conquer)",
    Value = { Min = 1, Max = 30, Default = 3 },
    Callback = function(v)
        CFG.switchDelay = v
    end,
})

AttackTab:Section({
    Title = "Weather Events",
    Icon = "cloud-lightning",
})

local WeatherVFX = GetBridge("WeatherVFX")

local activeWeather = {}

pcall(function()
    local conn = WeatherVFX:Connect(function(data)
        if not data or type(data) ~= "table" then return end
        local w = data.weather
        local a = data.action
        if a == "start" then
            activeWeather[w] = true
        elseif a == "stop" then
            activeWeather[w] = nil
        end
    end)
    table.insert(STATE.connections, conn)
end)

local weatherLabels = {}
for _, ev in WEATHER_EVENTS do
    table.insert(weatherLabels, ev.label)
end

AttackTab:Section({
    Title = "Raid Events",
    Icon = "flame",
})

AttackTab:Button({
    Title = "Show Raidable Weather Bases",
    Desc = "List all weather event bases currently on the map",
    Callback = function()
        local raidBases = {}
        for _, tag in ALL_CP_TAGS do
            for _, cp in CollectionService:GetTagged(tag) do
                if cp and cp.Parent and cp:IsDescendantOf(Workspace) then
                    local bt = cp:GetAttribute("baseType") or ""
                    local isWeatherBase = false
                    for _, ev in WEATHER_EVENTS do
                        for _, eb in ev.baseTypes do
                            if bt == eb then isWeatherBase = true break end
                        end
                        if isWeatherBase then break end
                    end
                    if isWeatherBase and not isOwned(cp) then
                        local cfg = GarnisonConfig[bt]
                        local dn = (cfg and cfg.displayName) or bt
                        table.insert(raidBases, dn .. " [" .. cp.Name .. "]")
                    end
                end
            end
        end
        if #raidBases > 0 then
            WindUI:Notify({
                Title = "Raid Bases",
                Content = #raidBases .. " available: " .. table.concat(raidBases, ", "),
                Duration = 8,
                Icon = "flame",
            })
        else
            WindUI:Notify({
                Title = "Raid Bases",
                Content = "No raidable weather bases found",
                Duration = 3,
                Icon = "cloud-off",
            })
        end
    end,
})

AttackTab:Dropdown({
    Title = "Select Raid Events",
    Desc = "Auto-attack bases that spawn during these events",
    Values = weatherLabels,
    Multi = true,
    AllowNone = true,
    Callback = function(sel)
        CFG.weatherEvents = sel or {}
    end,
})

UI_REFS.raidEnabled = AttackTab:Toggle({
    Title = "Auto Raid Weather Events",
    Desc = "Attack capture bases spawned by selected raid events",
    Value = false,
    Callback = function(state)
        CFG.raidEnabled = state
        if state then startRaidLoop() else killThread("raid") end
    end,
})

AttackTab:Button({
    Title = "Show Active Weather",
    Desc = "Notify which weather events are currently active",
    Callback = function()
        local active = {}
        for w, _ in activeWeather do
            for _, ev in WEATHER_EVENTS do
                if ev.id == w then
                    table.insert(active, ev.label)
                end
            end
        end
        if #active > 0 then
            WindUI:Notify({
                Title = "Active Weather",
                Content = table.concat(active, ", "),
                Duration = 5,
                Icon = "cloud-lightning",
            })
        else
            WindUI:Notify({
                Title = "Active Weather",
                Content = "No weather events active",
                Duration = 3,
                Icon = "cloud-off",
            })
        end
    end,
})

AttackTab:Section({
    Title = "Raid Events (KOTH / TKOTH)",
    Icon = "flame",
})

local raidEventLabels = {}
for _, ev in RAID_EVENTS do
    table.insert(raidEventLabels, ev.label)
end

AttackTab:Dropdown({
    Title = "Select Raid Events",
    Desc = "Auto-attack KOTH and Toxic KOTH bases when they spawn",
    Values = raidEventLabels,
    Multi = true,
    AllowNone = true,
    Callback = function(sel)
        CFG.raidEventBases = sel or {}
    end,
})

UI_REFS.raidEventArmy = AttackTab:Dropdown({
    Title = "Raid Event Army Slot",
    Values = {"1", "2", "3", "4", "5"},
    Value = "1",
    Callback = function(sel)
        CFG.raidEventArmy = tonumber(sel) or 1
    end,
})

UI_REFS.raidEventDelay = AttackTab:Slider({
    Title = "Raid Event Delay (sec)",
    Desc = "Delay between raid event scan cycles",
    Value = { Min = 1, Max = 60, Default = 5 },
    Callback = function(v)
        CFG.raidEventDelay = v
    end,
})

UI_REFS.raidEventEnabled = AttackTab:Toggle({
    Title = "Auto Raid Events",
    Desc = "Attack KOTH and Toxic KOTH bases when they appear",
    Value = false,
    Callback = function(state)
        CFG.raidEventEnabled = state
        if state then startRaidEventLoop() else killThread("raidEvent") end
    end,
})

AttackTab:Section({
    Title = "Auto Unclaim",
    Icon = "circle-minus",
})

local function getAllCPLabeled()
    local labels = {}
    local cpMap = {}
    for _, tag in ALL_CP_TAGS do
        for _, cp in CollectionService:GetTagged(tag) do
            if cp and cp.Parent and cp:IsDescendantOf(Workspace) then
                local baseType = cp:GetAttribute("baseType") or "Unknown"
                local cfg = GarnisonConfig[baseType]
                local displayName = (cfg and cfg.displayName) or baseType
                local parentFolder = cp.Parent and cp.Parent.Name or ""
                local label = displayName .. " (" .. parentFolder .. "/" .. cp.Name .. ")"
                table.insert(labels, label)
                cpMap[label] = cp
            end
        end
    end
    table.sort(labels)
    return labels, cpMap
end

local unclaimLabels, unclaimCPMap = getAllCPLabeled()

local UnclaimDropdown = AttackTab:Dropdown({
    Title = "Select Bases to Unclaim",
    Desc = "Pick bases you own to auto-unclaim",
    Values = unclaimLabels,
    Multi = true,
    AllowNone = true,
    Callback = function(sel)
        CFG.unclaimBases = sel or {}
    end,
})

AttackTab:Button({
    Title = "Refresh Unclaim List",
    Desc = "Re-scan available bases",
    Callback = function()
        unclaimLabels, unclaimCPMap = getAllCPLabeled()
        UnclaimDropdown:Refresh(unclaimLabels)
        WindUI:Notify({
            Title = "List Updated",
            Content = #unclaimLabels .. " bases found",
            Duration = 2,
            Icon = "refresh-cw",
        })
    end,
})

UI_REFS.unclaimEnabled = AttackTab:Toggle({
    Title = "Enable Auto Unclaim",
    Value = false,
    Callback = function(state)
        CFG.unclaimEnabled = state
        if state then startUnclaimLoop() else killThread("unclaim") end
    end,
})

local ShopTab = Window:Tab({
    Title = "Shop",
    Icon = "store",
})

ShopTab:Section({
    Title = "Quick Actions",
    Icon = "mouse-pointer-click",
})

ShopTab:Button({
    Title = "Open Shop",
    Callback = function()
        pcall(function() GetSignal("OpenShop"):Fire() end)
    end,
})

ShopTab:Button({
    Title = "Open Quests",
    Callback = function()
        pcall(function() GetSignal("OpenQuests"):Fire() end)
        pcall(function() GetSignal("ShowQuests"):Fire() end)
        pcall(function() GetSignal("ToggleQuests"):Fire() end)
    end,
})

ShopTab:Button({
    Title = "Open Black Market",
    Callback = function()
        pcall(function() GetSignal("OpenBlackMarketShop"):Fire() end)
    end,
})

ShopTab:Button({
    Title = "Open Crafting",
    Callback = function()
        pcall(function() GetSignal("OpenCraftingUI"):Fire() end)
    end,
})

ShopTab:Section({
    Title = "Auto Buy",
    Icon = "shopping-cart",
})

local houseItems = getShopItems("House")
local farmItems = getShopItems("Farm")
local bmItems = getShopItems("BlackMarket")
local milItems = getShopItems("Military")
local decorItems = getShopItems("Decor")

ShopTab:Dropdown({
    Title = "Farm",
    Values = farmItems,
    Multi = true,
    AllowNone = true,
    Callback = function(sel) CFG.buyFarms = sel or {} end,
})

ShopTab:Dropdown({
    Title = "House",
    Values = houseItems,
    Multi = true,
    AllowNone = true,
    Callback = function(sel) CFG.buyHouses = sel or {} end,
})

ShopTab:Dropdown({
    Title = "Decor",
    Values = decorItems,
    Multi = true,
    AllowNone = true,
    Callback = function(sel) CFG.buyDecor = sel or {} end,
})

ShopTab:Dropdown({
    Title = "Military",
    Values = milItems,
    Multi = true,
    AllowNone = true,
    Callback = function(sel) CFG.buyMilitary = sel or {} end,
})

ShopTab:Dropdown({
    Title = "Black Market",
    Values = bmItems,
    Multi = true,
    AllowNone = true,
    Callback = function(sel) CFG.buyBlackMarket = sel or {} end,
})

UI_REFS.buyDelay = ShopTab:Slider({
    Title = "Buy Delay (sec)",
    Value = { Min = 1, Max = 10, Default = 2 },
    Callback = function(v) CFG.buyDelay = v end,
})

UI_REFS.autoBuyEnabled = ShopTab:Toggle({
    Title = "Auto Buy Selected",
    Desc = "Buy items selected above from each category",
    Value = false,
    Callback = function(state)
        CFG.autoBuyEnabled = state
        if state then startBuySelectedLoop() else killThread("buySelected") end
    end,
})

UI_REFS.autoBuyAll = ShopTab:Toggle({
    Title = "Auto Buy ALL",
    Desc = "Buy every item from all categories",
    Value = false,
    Callback = function(state)
        CFG.autoBuyAll = state
        if state then startBuyAllLoop() else killThread("buyAll") end
    end,
})

ShopTab:Section({
    Title = "Auto Sell",
    Icon = "banknote",
})

UI_REFS.autoSellThreshold = ShopTab:Slider({
    Title = "Sell at Market %",
    Desc = "Auto sell when average market reaches this %",
    Value = { Min = 50, Max = 1000, Default = 150 },
    Callback = function(v)
        CFG.autoSellThreshold = v
    end,
})

UI_REFS.autoSellEnabled = ShopTab:Toggle({
    Title = "Auto Sell at %",
    Desc = "Sell all resources when average market % reaches threshold",
    Value = false,
    Callback = function(state)
        CFG.autoSellEnabled = state
        if state then startAutoSellLoop() else killThread("autoSell") end
    end,
})

ShopTab:Button({
    Title = "Sell All Now",
    Desc = "Sell all resources immediately",
    Callback = function()
        pcall(function() SellAll:Fire() end)
        WindUI:Notify({
            Title = "Shop",
            Content = "All resources sold!",
            Duration = 3,
            Icon = "check",
        })
    end,
})

local FarmTab = Window:Tab({
    Title = "Auto Farm",
    Icon = "sprout",
})

FarmTab:Section({
    Title = "Auto Crafting",
    Icon = "hammer",
})

local craftRecipes = getCraftingRecipes()

FarmTab:Dropdown({
    Title = "Select Recipes",
    Desc = "Pick items to auto-craft",
    Values = craftRecipes,
    Multi = true,
    AllowNone = true,
    Callback = function(sel) CFG.craftRecipes = sel or {} end,
})

UI_REFS.autoCraftEnabled = FarmTab:Toggle({
    Title = "Auto Craft",
    Desc = "Automatically start and claim crafts",
    Value = false,
    Callback = function(state)
        CFG.autoCraftEnabled = state
        if state then startCraftLoop() else killThread("craft") end
    end,
})

FarmTab:Section({
    Title = "Auto Collect",
    Icon = "sprout",
})

UI_REFS.autoCollectFarms = FarmTab:Toggle({
    Title = "Auto Collect Farms",
    Desc = "Collect resources from farms, gem mines, and clone facilities",
    Value = false,
    Callback = function(state)
        CFG.autoCollectFarms = state
        if state then startAutoCollectFarmsLoop() else killThread("collectFarms") end
    end,
})

UI_REFS.collectFarmDelay = FarmTab:Slider({
    Title = "Collect Delay (sec)",
    Desc = "Delay between farm collection cycles",
    Value = { Min = 2, Max = 60, Default = 10 },
    Callback = function(v)
        CFG.collectFarmDelay = v
    end,
})

UI_REFS.autoCollectBP = FarmTab:Toggle({
    Title = "Auto Collect BP Tickets",
    Desc = "Collect battlepass pickup coins from the map",
    Value = false,
    Callback = function(state)
        CFG.autoCollectBP = state
        if state then startAutoCollectBPLoop() else killThread("collectBP") end
    end,
})

local MiscTab = Window:Tab({
    Title = "Misc",
    Icon = "settings-2",
})

MiscTab:Section({
    Title = "Automation",
    Icon = "bot",
})

UI_REFS.antiAfk = MiscTab:Toggle({
    Title = "Anti AFK",
    Value = false,
    Callback = function(state)
        CFG.antiAfk = state
        if state then startAntiAfkLoop() else killThread("antiAfk") end
    end,
})

MiscTab:Section({
    Title = "Rewards",
    Icon = "gift",
})

MiscTab:Button({
    Title = "Claim Daily Reward",
    Desc = "Claim today's daily login reward",
    Callback = function()
        pcall(function() GetBridge("DailyRewardsClaim"):Fire() end)
        WindUI:Notify({
            Title = "Rewards",
            Content = "Daily reward claimed!",
            Duration = 3,
            Icon = "check",
        })
    end,
})

MiscTab:Button({
    Title = "Claim Returning Reward",
    Desc = "Claim returning player daily reward",
    Callback = function()
        pcall(function() GetBridge("ClaimReturningDailyReward"):Fire() end)
        WindUI:Notify({
            Title = "Rewards",
            Content = "Returning reward claimed!",
            Duration = 3,
            Icon = "check",
        })
    end,
})

MiscTab:Button({
    Title = "Claim Like Reward",
    Desc = "Claim the game like reward",
    Callback = function()
        pcall(function() GetBridge("ClaimLikeReward"):Fire() end)
        WindUI:Notify({
            Title = "Rewards",
            Content = "Like reward claimed!",
            Duration = 3,
            Icon = "check",
        })
    end,
})

MiscTab:Button({
    Title = "Claim Battlepass Rewards",
    Desc = "Claim all available battlepass tiers (Free + Premium)",
    Callback = function()
        for stage = 1, 50 do
            pcall(function() GetBridge("ClaimBPReward"):Fire({track = "Free", stage = stage}) end)
            task.wait(0.1)
            pcall(function() GetBridge("ClaimBPReward"):Fire({track = "Premium", stage = stage}) end)
            task.wait(0.1)
        end
        WindUI:Notify({
            Title = "Battlepass",
            Content = "Claimed all 50 tiers on both tracks!",
            Duration = 3,
            Icon = "check",
        })
    end,
})

UI_REFS.autoClaimBP = MiscTab:Toggle({
    Title = "Auto Claim Battlepass",
    Desc = "Auto claim all battlepass tiers every 60s",
    Value = false,
    Callback = function(state)
        CFG.autoClaimBP = state
        if state then startClaimBPLoop() else killThread("claimBP") end
    end,
})

UI_REFS.autoClaimAll = MiscTab:Toggle({
    Title = "Auto Claim All",
    Desc = "Auto claim daily, returning, and like rewards every 60s",
    Value = false,
    Callback = function(state)
        CFG.autoClaimAll = state
        if state then startClaimAllLoop() else killThread("claimAll") end
    end,
})

MiscTab:Section({
    Title = "Rejoin",
    Icon = "rotate-ccw",
})

UI_REFS.autoRejoin = MiscTab:Toggle({
    Title = "Auto Rejoin",
    Desc = "Rejoin when kicked or disconnected",
    Value = false,
    Callback = function(state)
        CFG.autoRejoin = state
        if state then
            startRejoin()
            WindUI:Notify({
                Title = "Auto Rejoin",
                Content = "Will rejoin on kick/disconnect",
                Duration = 3,
                Icon = "rotate-ccw",
            })
        else
            killThread("rejoinDetect")
            if STATE.connections.rejoinTeleport then
                pcall(function() STATE.connections.rejoinTeleport:Disconnect() end)
                STATE.connections.rejoinTeleport = nil
            end
        end
    end,
})

UI_REFS.sameServer = MiscTab:Toggle({
    Title = "Same Server",
    Desc = "Try to rejoin the same server (falls back to new server)",
    Value = false,
    Callback = function(state)
        CFG.sameServer = state
    end,
})

MiscTab:Button({
    Title = "Rejoin Now",
    Desc = "Immediately rejoin the server",
    Callback = function()
        saveRejoinLoader()
        queueRejoinExec()
        pcall(function()
            if CFG.sameServer then
                TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
            else
                TeleportService:Teleport(game.PlaceId, LocalPlayer)
            end
        end)
    end,
})

UI_REFS.disableNotifs = MiscTab:Toggle({
    Title = "Disable Notifications",
    Value = false,
    Callback = function(state)
        CFG.disableNotifs = state
        if state then startNotifBlock() else killThread("notifBlock") end
    end,
})

UI_REFS.blockPopups = MiscTab:Toggle({
    Title = "Block In-Game Popups",
    Value = false,
    Callback = function(state)
        CFG.blockPopups = state
        if state then startPopupBlock() else killThread("popupBlock") end
    end,
})

local PerfTab = Window:Tab({
    Title = "Performance",
    Icon = "gauge",
})

PerfTab:Section({
    Title = "Graphics & Rendering",
    Icon = "monitor",
})

UI_REFS.cullDistance = PerfTab:Slider({
    Title = "NPC Cull Distance",
    Desc = "Hide NPCs beyond this distance (studs)",
    Value = { Min = 1, Max = 1000, Default = 500 },
    Callback = function(v)
        CFG.cullDistance = v
    end,
})

UI_REFS.cullEnabled = PerfTab:Toggle({
    Title = "Enable NPC Culling",
    Desc = "Hide NPCs beyond cull distance",
    Value = false,
    Callback = function(state)
        CFG.cullEnabled = state
        if state then
            startCullLoop()
        else
            killThread("cull")
            pcall(function()
                for _, model in Workspace:GetDescendants() do
                    if model:IsA("Model") then
                        for _, part in model:GetDescendants() do
                            if part:IsA("BasePart") then
                                part.LocalTransparencyModifier = 0
                            end
                        end
                    end
                end
            end)
        end
    end,
})

UI_REFS.lowPerf = PerfTab:Toggle({
    Title = "Low Performance Mode",
    Desc = "Disable particles, shadows and effects",
    Value = false,
    Callback = function(state)
        CFG.lowPerf = state
        if state then
            Lighting.GlobalShadows = false
            Lighting.FogEnd = 1e6
            pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
            for _, v in Workspace:GetDescendants() do
                if v:IsA("ParticleEmitter") then v.Enabled = false end
                if v:IsA("Trail") then v.Enabled = false end
                if v:IsA("Beam") then v.Enabled = false end
                if v:IsA("Fire") then v.Enabled = false end
                if v:IsA("Smoke") then v.Enabled = false end
                if v:IsA("Sparkles") then v.Enabled = false end
            end
        else
            Lighting.GlobalShadows = true
            pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level08 end)
            for _, v in Workspace:GetDescendants() do
                if v:IsA("ParticleEmitter") or v:IsA("Trail") or v:IsA("Beam")
                    or v:IsA("Fire") or v:IsA("Smoke") or v:IsA("Sparkles") then
                    v.Enabled = true
                end
            end
        end
    end,
})

UI_REFS.removeFog = PerfTab:Toggle({
    Title = "Remove Fog",
    Value = false,
    Callback = function(state)
        CFG.removeFog = state
        if state then
            Lighting.FogEnd = 1e6
            Lighting.FogStart = 0
            Lighting.Atmosphere.Density = 0
        else
            Lighting.FogEnd = 100000
            Lighting.FogStart = 0
            Lighting.Atmosphere.Density = 0.3
        end
    end,
})

local blackScreenGui = nil

UI_REFS.blackScreen = PerfTab:Toggle({
    Title = "Black Screen",
    Desc = "Cover the entire screen in black",
    Value = false,
    Callback = function(state)
        CFG.blackScreen = state
        if state then
            if not blackScreenGui then
                blackScreenGui = Instance.new("ScreenGui")
                blackScreenGui.Name = "NexusBlackScreen"
                blackScreenGui.IgnoreGuiInset = true
                blackScreenGui.DisplayOrder = 999
                local frame = Instance.new("Frame")
                frame.Size = UDim2.fromScale(1, 1)
                frame.BackgroundColor3 = Color3.new(0, 0, 0)
                frame.BorderSizePixel = 0
                frame.Parent = blackScreenGui
                blackScreenGui.Parent = LocalPlayer.PlayerGui
            end
            blackScreenGui.Enabled = true
        else
            if blackScreenGui then
                blackScreenGui.Enabled = false
            end
        end
    end,
})

UI_REFS.disable3D = PerfTab:Toggle({
    Title = "Disable 3D Rendering",
    Desc = "Stops rendering the 3D world",
    Value = false,
    Callback = function(state)
        CFG.disable3D = state
        pcall(function()
            RunService:Set3dRenderingEnabled(not state)
        end)
    end,
})

UI_REFS.antiLag = PerfTab:Toggle({
    Title = "Anti Lag (Reduced Graphics)",
    Desc = "Full graphics reduction for maximum FPS",
    Value = false,
    Callback = function(state)
        CFG.antiLag = state
        if state then
            Lighting.GlobalShadows = false
            Lighting.FogEnd = 1e6
            Lighting.Brightness = 0
            pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
            pcall(function() RunService:Set3dRenderingEnabled(false) end)
            for _, v in Workspace:GetDescendants() do
                if v:IsA("ParticleEmitter") then v.Enabled = false end
                if v:IsA("Trail") then v.Enabled = false end
                if v:IsA("Beam") then v.Enabled = false end
                if v:IsA("Fire") then v.Enabled = false end
                if v:IsA("Smoke") then v.Enabled = false end
                if v:IsA("Sparkles") then v.Enabled = false end
                if v:IsA("Explosion") then v.Visible = false end
            end
        else
            Lighting.GlobalShadows = true
            Lighting.Brightness = 2
            pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level08 end)
        end
    end,
})

UI_REFS.hideOtherPlots = PerfTab:Toggle({
    Title = "Hide Other Plots",
    Desc = "Only show your own plot buildings",
    Value = false,
    Callback = function(state)
        CFG.hideOtherPlots = state
        if state then
            startHidePlotsLoop()
        else
            killThread("hidePlots")
            pcall(function()
                for _, tag in CollectionService:GetTags() do
                    if tag:match("-Plot$") then
                        for _, obj in CollectionService:GetTagged(tag) do
                            if obj:IsA("Model") or obj:IsA("Folder") then
                                for _, d in obj:GetDescendants() do
                                    if d:IsA("BasePart") then
                                        d.LocalTransparencyModifier = 0
                                    end
                                end
                            end
                        end
                    end
                end
            end)
        end
    end,
})

local SettingsTab = Window:Tab({
    Title = "Settings",
    Icon = "settings",
})

SettingsTab:Section({
    Title = "Configs",
    Icon = "save",
})

local configList = getConfigNames()
local configNameText = ""
local selectedConfigName = nil

local function syncUIFromConfig()
    for key, ref in pairs(UI_REFS) do
        pcall(function()
            if ref and CFG[key] ~= nil then
                if ref.Select then
                    ref:Select(CFG[key])
                elseif ref.Set then
                    ref:Set(CFG[key])
                end
            end
        end)
    end
end

local ConfigDropdown = SettingsTab:Dropdown({
    Title = "Config List",
    Values = configList,
    Value = configList[1],
    AllowNone = true,
    Callback = function(sel)
        selectedConfigName = sel
    end,
})

local configNameInput = SettingsTab:Input({
    Title = "Config Name",
    Placeholder = "Enter name...",
    Callback = function(val)
        configNameText = val or ""
    end,
})

local autoloadLabel = SettingsTab:Paragraph({
    Title = "AutoLoad: None",
    Content = "No autoload config set",
})

local currentAutoLoad = getAutoLoad()
if currentAutoLoad and currentAutoLoad ~= "" then
    pcall(function() autoloadLabel:SetTitle("AutoLoad: " .. currentAutoLoad) end)
end

SettingsTab:Button({
    Title = "Create Config",
    Callback = function()
        local name = configNameText
        if name and name ~= "" then
            saveConfig(name)
            local newList = getConfigNames()
            ConfigDropdown:Refresh(newList)
            WindUI:Notify({
                Title = "Config Saved",
                Content = "Created config: " .. name,
                Duration = 3,
                Icon = "check",
            })
        else
            WindUI:Notify({
                Title = "Error",
                Content = "Enter a config name first",
                Duration = 3,
                Icon = "alert-circle",
            })
        end
    end,
})

SettingsTab:Button({
    Title = "Load Config",
    Callback = function()
        local name = selectedConfigName or ConfigDropdown.Value
        if name then
            loadConfig(name)
            syncUIFromConfig()
            applyConfig()
            WindUI:Notify({
                Title = "Config Loaded",
                Content = "Loaded: " .. name,
                Duration = 3,
                Icon = "download",
            })
        end
    end,
})

SettingsTab:Button({
    Title = "Overwrite Config",
    Callback = function()
        local name = selectedConfigName or ConfigDropdown.Value
        if name then
            saveConfig(name)
            WindUI:Notify({
                Title = "Config Overwritten",
                Content = "Overwritten: " .. name,
                Duration = 3,
                Icon = "refresh-cw",
            })
        end
    end,
})

SettingsTab:Button({
    Title = "Delete Config",
    Callback = function()
        local name = selectedConfigName or ConfigDropdown.Value
        if name then
            deleteConfig(name)
            local newList = getConfigNames()
            ConfigDropdown:Refresh(newList)
            WindUI:Notify({
                Title = "Config Deleted",
                Content = "Deleted: " .. name,
                Duration = 3,
                Icon = "trash-2",
            })
        end
    end,
})

SettingsTab:Button({
    Title = "Refresh Lists",
    Callback = function()
        local newList = getConfigNames()
        ConfigDropdown:Refresh(newList)
        WindUI:Notify({
            Title = "Refreshed",
            Content = "Config list updated",
            Duration = 2,
            Icon = "refresh-cw",
        })
    end,
})

SettingsTab:Button({
    Title = "Set As AutoLoad",
    Callback = function()
        local name = selectedConfigName or ConfigDropdown.Value
        if name then
            setAutoLoad(name)
            pcall(function() autoloadLabel:SetTitle("AutoLoad: " .. name) end)
            WindUI:Notify({
                Title = "AutoLoad Set",
                Content = name .. " will load on startup",
                Duration = 3,
                Icon = "check-circle",
            })
        end
    end,
})

SettingsTab:Button({
    Title = "Reset AutoLoad",
    Callback = function()
        resetAutoLoad()
        pcall(function() autoloadLabel:SetTitle("AutoLoad: None") end)
        WindUI:Notify({
            Title = "AutoLoad Reset",
            Content = "AutoLoad cleared",
            Duration = 3,
            Icon = "x-circle",
        })
    end,
})

SettingsTab:Section({
    Title = "Menu Bind",
    Icon = "keyboard",
})

SettingsTab:Dropdown({
    Title = "Toggle Menu Key",
    Values = KEY_NAMES,
    Value = CFG.menuBind,
    Callback = function(sel)
        CFG.menuBind = sel
        local code = KEY_MAP[sel]
        if code then
            pcall(function() Window:SetToggleKey(code) end)
        end
    end,
})

SettingsTab:Section({
    Title = "Info",
    Icon = "info",
})

SettingsTab:Button({
    Title = "Destroy Hub",
    Callback = function()
        for _, t in STATE.threads do
            pcall(function() task.cancel(t) end)
        end
        for _, c in STATE.connections do
            pcall(function() c:Disconnect() end)
        end
        pcall(function()
            RunService:Set3dRenderingEnabled(true)
            Lighting.GlobalShadows = true
        end)
        if blackScreenGui then
            pcall(function() blackScreenGui:Destroy() end)
        end
        pcall(function() bubbleGui:Destroy() end)
        Window:Destroy()
    end,
})

task.spawn(function()
    local autoName = getAutoLoad()
    if autoName and autoName ~= "" then
        loadConfig(autoName)
    end
    task.wait(1)
    syncUIFromConfig()
    applyConfig()
    if autoName and autoName ~= "" then
        WindUI:Notify({
            Title = "Auto Loaded",
            Content = "Config: " .. autoName,
            Duration = 3,
            Icon = "download",
        })
    end
end)

local bubbleGui = Instance.new("ScreenGui")
bubbleGui.Name = "NexusBubble"
bubbleGui.ResetOnSpawn = false
bubbleGui.IgnoreGuiInset = true
bubbleGui.DisplayOrder = 100

local bubble = Instance.new("TextButton")
bubble.Name = "Bubble"
bubble.Text = "Nexus"
bubble.Font = Enum.Font.GothamBold
bubble.TextSize = 14
bubble.TextColor3 = Color3.new(1, 1, 1)
bubble.BackgroundColor3 = Color3.fromRGB(80, 50, 200)
bubble.Size = UDim2.fromOffset(60, 60)
bubble.Position = UDim2.fromOffset(20, 200)
bubble.BorderSizePixel = 0
bubble.AutoButtonColor = true
bubble.Parent = bubbleGui

local bubbleCorner = Instance.new("UICorner")
bubbleCorner.CornerRadius = UDim.new(1, 0)
bubbleCorner.Parent = bubble

local bubbleStroke = Instance.new("UIStroke")
bubbleStroke.Color = Color3.fromRGB(120, 80, 255)
bubbleStroke.Thickness = 2
bubbleStroke.Parent = bubble

local dragging = false
local dragStart, startPos
local windowOpen = false

bubble.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        startPos = bubble.Position
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement) then
        local delta = input.Position - dragStart
        bubble.Position = UDim2.fromOffset(
            startPos.X.Offset + delta.X,
            startPos.Y.Offset + delta.Y
        )
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if not dragging then return end
    if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
        local delta = dragStart and (input.Position - dragStart).Magnitude or 0
        dragging = false
        if delta < 10 then
            windowOpen = not windowOpen
            pcall(function()
                if windowOpen then
                    Window:Open()
                else
                    Window:Close()
                end
            end)
        end
    end
end)

pcall(function()
    Window:OnOpen(function() windowOpen = true end)
    Window:OnClose(function() windowOpen = false end)
end)

bubbleGui.Parent = game:GetService("CoreGui")

task.wait(1)
WindUI:Notify({
    Title = "Nexus HUB",
    Content = "Loaded successfully! Press your bind or tap the bubble.",
    Duration = 4,
    Icon = "zap",
})
