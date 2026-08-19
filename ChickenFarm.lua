local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
local IsAlive = (typeof(STATE) == "table" and typeof(STATE.alive) == "function")
	and function()
		return STATE.alive()
	end
	or function()
		return true
	end

local Paper = require(game.ReplicatedStorage.Paper)
local Stats = Paper.Stats
local function GetStat(key)
	local v = Stats.GetValue(key)
	pcall(setthreadcontext, 8)
	return v
end
local Network = Paper.Network
local MultiplierValue = game.ReplicatedStorage.Values:WaitForChild("EggMultiplier")
local ChickensModule = require(game.ReplicatedStorage.Modules.Shared.Chickens)
local ChickensTable = require(game.ReplicatedStorage.Tables.Chickens)
local CollectableClient = Paper.CollectableClient
local LocalPlayer = game.Players.LocalPlayer
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local PlaceId = game.PlaceId

local flags = {
	antiAfk = true,
	autoCollect = false,
	auraCollect = false,
	auraRadius = 30,
	autoMoney = false,
	autoSell = false,
	sellMult = 1.2,
	autoBlocks = false,
	autoOpen = false,
	autoDiscard = false,
	autoRebirth = false,
	rebirthMult = 1,
	autoBuy = false,
	buyAmount = 25,
	autoMerge = false,
	walkSpeed = false,
	walkSpeedVal = 16,
	fly = false,
	flySpeed = 50,
	autoRejoin = false,
	rejoinInterval = 600,
	autoCodes = false,
	codes = {},
	codeInterval = 30,
	autoGroupReward = false,
	autoOfflineEarnings = false,
}

local function fmt(n)
	n = n or 0
	if n >= 1e15 then
		return ("%.2fQ"):format(n / 1e15)
	elseif n >= 1e12 then
		return ("%.2fT"):format(n / 1e12)
	elseif n >= 1e9 then
		return ("%.2fB"):format(n / 1e9)
	elseif n >= 1e6 then
		return ("%.2fM"):format(n / 1e6)
	elseif n >= 1e3 then
		return ("%.2fK"):format(n / 1e3)
	end
	return ("%d"):format(math.floor(n))
end

local function collectEgg(egg)
	if egg:GetAttribute("Tier") == nil then
		return false
	end
	Network.FireServer("Collect Egg", egg.Name)
	egg:Destroy()
	return true
end

local function tryCollect()
	local eggs = workspace:FindFirstChild("Eggs")
	if not eggs then
		return
	end
	local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	local pos = root and root.Position
	for _, egg in eggs:GetChildren() do
		if egg:GetAttribute("Tier") ~= nil then
			local should = flags.autoCollect
			if not should and flags.auraCollect and pos then
				local ok, dist = pcall(function()
					return (egg.Position - pos).Magnitude
				end)
				if ok and dist <= flags.auraRadius then
					should = true
				end
			end
			if should then
				collectEgg(egg)
			end
		end
	end
end

local function tryCollectBlock()
	if GetStat("EquippedLuckyBlock") ~= 0 then
		return
	end
	local eggs = workspace:FindFirstChild("Eggs")
	if not eggs then
		return
	end
	for _, blk in eggs:GetChildren() do
		if blk:GetAttribute("LuckyBlock") ~= nil then
			local ok = pcall(function()
				return Network.InvokeServer("Collect Lucky Block", blk.Name)
			end)
			if ok then
				blk:Destroy()
			end
		end
	end
end

local function tryOpenBlock()
	local equipped = GetStat("EquippedLuckyBlock")
	if equipped == 0 then
		return
	end
	if GetStat("IsCurrentLuckyBlockFree") then
		pcall(function()
			Network.InvokeServer("Open Lucky Block")
		end)
		return
	end
	local okCost, cost = pcall(function()
		return ChickensModule.GetLuckyBlockCost(
			GetStat("TotalChickens"),
			equipped,
			GetStat("Rebirth")
		)
	end)
	if not okCost or GetStat("Cash") < cost then
		return
	end
	local ok, result = pcall(function()
		return Network.InvokeServer("Open Lucky Block")
	end)
	if ok and result then
		Network.FireServer("Claim Opened Chicken")
	end
end

local lastDiscard = 0
local function tryDiscardBlock()
	local equipped = GetStat("EquippedLuckyBlock")
	if equipped == 0 then
		return
	end
	if GetStat("IsCurrentLuckyBlockFree") then
		return
	end
	local okCost, cost = pcall(function()
		return ChickensModule.GetLuckyBlockCost(
			GetStat("TotalChickens"),
			equipped,
			GetStat("Rebirth")
		)
	end)
	if not okCost or GetStat("Cash") >= cost then
		return
	end
	if os.clock() - lastDiscard < 2 then
		return
	end
	lastDiscard = os.clock()
	Network.FireServer("Discard Lucky Block")
end

local lastRebirth = 0
local function tryRebirth()
	local rebirth = GetStat("Rebirth")
	local cash = GetStat("Cash")
	local req = ChickensModule.GetRebirthReq(rebirth + 1)
	if not req or cash < req then
		return
	end
	if ChickensModule.GetRebirthBoost(rebirth + 1) < flags.rebirthMult then
		return
	end
	if os.clock() - lastRebirth < 2 then
		return
	end
	lastRebirth = os.clock()
	pcall(function()
		Network.InvokeServer("Rebirth")
	end)
end

local lastBuy = 0
local function tryBuy()
	local cost = ChickensModule.GetBuyChickenCost(
		GetStat("TotalChickens"),
		GetStat("BuyTierLevel"),
		flags.buyAmount
	)
	if GetStat("Cash") < cost then
		return
	end
	if os.clock() - lastBuy < 0.5 then
		return
	end
	lastBuy = os.clock()
	pcall(function()
		Network.InvokeServer("Buy Chickens", flags.buyAmount)
	end)
end

local lastMerge = 0
local function tryMerge()
	local chickens = GetStat("Chickens")
	if type(chickens) ~= "table" then
		return
	end
	local maxTier = #ChickensTable
	for tier, count in chickens do
		if count >= 3 and tier < maxTier then
			if os.clock() - lastMerge < 1.5 then
				return
			end
			lastMerge = os.clock()
			pcall(function()
				Network.InvokeServer("Merge Chickens")
			end)
			return
		end
	end
end

local function fetchServers()
	local ok, res = pcall(request, {
		Url = "https://games.roblox.com/v1/games/" .. PlaceId .. "/servers/Public?limit=100",
		Method = "GET",
		Headers = { ["accept"] = "application/json" },
	})
	if not ok or not res or res.StatusCode ~= 200 then
		return nil
	end
	local okd, data = pcall(HttpService.JSONDecode, HttpService, res.Body)
	if not okd or type(data) ~= "table" then
		return nil
	end
	local open = {}
	for _, srv in ipairs(data.data or {}) do
		if srv.playing < srv.maxPlayers then
			table.insert(open, srv)
		end
	end
	return open
end

local function serverHop()
	local open = fetchServers()
	if not open or #open == 0 then
		pcall(function()
			TeleportService:TeleportToPlace(PlaceId)
		end)
		return
	end
	local srv = open[math.random(1, #open)]
	pcall(function()
		TeleportService:TeleportToPlaceInstance(PlaceId, srv.id)
	end)
end

local function rejoinServer()
	pcall(function()
		TeleportService:TeleportToPlaceInstance(PlaceId, game.JobId)
	end)
end

local lastCode = 0
local function tryRedeemCodes()
	if os.clock() - lastCode < flags.codeInterval then
		return
	end
	local codes = flags.codes
	if type(codes) ~= "table" or #codes == 0 then
		return
	end
	lastCode = os.clock()
	local code = codes[math.random(1, #codes)]
	local ok, result = pcall(function()
		return Network.InvokeServer("Redeem Code", code)
	end)
	if ok and result then
		warn("[CFH] Code '" .. tostring(code) .. "' redeemed")
	end
end

local lastGroupReward = 0
local function tryGroupReward()
	if os.clock() - lastGroupReward < 30 then
		return
	end
	if not GetStat("InGroup") then
		return
	end
	local last = GetStat("LastGroupClaim") or 0
	if os.time() - last < 600 then
		return
	end
	lastGroupReward = os.clock()
	pcall(function()
		Network.InvokeServer("Claim Group Reward")
	end)
end

local function tryOfflineEarnings()
	local amount = GetStat("OfflineEarnings") or 0
	if amount <= 0 then
		return
	end
	pcall(function()
		Network.InvokeServer("Claim Offline Earnings")
	end)
end

local function applyWalkSpeed()
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = flags.walkSpeed and flags.walkSpeedVal or 16
	end
end

local FlyBV = nil
local function updateFly()
	if not flags.fly then
		if FlyBV and FlyBV.Parent then
			FlyBV:Destroy()
		end
		FlyBV = nil
		return
	end
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root then
		return
	end
	if not FlyBV or FlyBV.Parent == nil then
		FlyBV = Instance.new("BodyVelocity")
		FlyBV.MaxForce = Vector3.new(1e5, 1e5, 1e5)
		FlyBV.Parent = root
		if hum then
			hum.PlatformStand = true
		end
	end
	local cam = workspace.CurrentCamera
	local dir = Vector3.zero
	local look = cam.CFrame.LookVector
	local right = cam.CFrame.RightVector
	if UIS:IsKeyDown(Enum.KeyCode.W) then
		dir += Vector3.new(look.X, 0, look.Z)
	end
	if UIS:IsKeyDown(Enum.KeyCode.S) then
		dir -= Vector3.new(look.X, 0, look.Z)
	end
	if UIS:IsKeyDown(Enum.KeyCode.A) then
		dir -= Vector3.new(right.X, 0, right.Z)
	end
	if UIS:IsKeyDown(Enum.KeyCode.D) then
		dir += Vector3.new(right.X, 0, right.Z)
	end
	if dir.Magnitude > 0 then
		dir = dir.Unit
	end
	if UIS:IsKeyDown(Enum.KeyCode.Space) then
		dir += Vector3.new(0, 1, 0)
	end
	if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then
		dir += Vector3.new(0, -1, 0)
	end
	FlyBV.Velocity = dir * flags.flySpeed
end

local function loop(fn)
	task.spawn(function()
		pcall(setthreadcontext, 8)
		while IsAlive() do
			local ok, err = pcall(fn)
			if not ok then
				warn("[CFH] " .. tostring(err))
			end
			task.wait(0.5)
		end
	end)
end

loop(function()
	if flags.autoCollect or flags.auraCollect then
		tryCollect()
	end
end)

loop(function()
	if flags.autoMoney then
		local cash = GetStat("CashCollect")
		if cash and cash > 0 then
			Network.InvokeServer("Collect Cash")
		end
	end
end)

loop(function()
	if flags.autoSell then
		local eggs = GetStat("Eggs")
		if eggs and eggs > 0 and MultiplierValue.Value >= flags.sellMult then
			Network.InvokeServer("Deposit Eggs")
		end
	end
end)

loop(function()
	if flags.autoBlocks then
		tryCollectBlock()
	end
end)

loop(function()
	if flags.autoOpen then
		tryOpenBlock()
	end
end)

loop(function()
	if flags.autoDiscard then
		tryDiscardBlock()
	end
end)

loop(function()
	if flags.autoRebirth then
		tryRebirth()
	end
end)

loop(function()
	if flags.autoBuy then
		tryBuy()
	end
end)

loop(function()
	if flags.autoMerge then
		tryMerge()
	end
end)

loop(function()
	if flags.autoGroupReward then
		tryGroupReward()
	end
end)

loop(function()
	if flags.autoOfflineEarnings then
		tryOfflineEarnings()
	end
end)

loop(function()
	if flags.autoCodes then
		tryRedeemCodes()
	end
end)

loop(function()
	if flags.walkSpeed then
		applyWalkSpeed()
	end
end)

if typeof(STATE) == "table" and STATE.connect then
	STATE.connect(RunService.RenderStepped, updateFly)
else
	RunService.RenderStepped:Connect(updateFly)
end

LocalPlayer.CharacterAdded:Connect(function()
	applyWalkSpeed()
end)

if typeof(STATE) == "table" and STATE.namecallHook then
	STATE.namecallHook("Kick", function(self, method, ...)
		if flags.autoRejoin and self == LocalPlayer then
			task.spawn(function()
				task.wait(0.5)
				serverHop()
			end)
			return true
		end
	end)
end

local lastBlockCollect = 0
pcall(function()
	CollectableClient.OnCollectableAdded(function(info)
		if info.Type == "LuckyBlock" and flags.autoBlocks and os.clock() - lastBlockCollect > 1 then
			if GetStat("EquippedLuckyBlock") == 0 then
				lastBlockCollect = os.clock()
				pcall(function()
					CollectableClient.Collect(info.Id)
				end)
			end
		end
	end)
end)

task.spawn(function()
	pcall(setthreadcontext, 8)
	local Vim = game:GetService("VirtualInputManager")
	local key = Enum.KeyCode.LeftShift
	while IsAlive() do
		task.wait(30)
		if flags.antiAfk then
			pcall(function()
				Vim:SendKeyEvent(true, key, false, game)
				Vim:SendKeyEvent(false, key, false, game)
			end)
		end
	end
end)

local Window
Window = WindUI:CreateWindow({
	Title = "Chicken Farm Hub",
	Author = "auto farm",
	Icon = "egg",
	Folder = "ChickenFarmHub",
	Size = UDim2.fromOffset(540, 470),
	MinSize = Vector2.new(460, 400),
	MaxSize = Vector2.new(720, 640),
	Theme = "Dark",
	NewElements = true,
	HideSearchBar = true,
	Resizable = true,
	Acrylic = true,
	ToggleKey = Enum.KeyCode.LeftControl,
	OpenButton = {
		Title = "CFH",
		Icon = "egg",
		CornerRadius = UDim.new(0, 14),
		StrokeThickness = 2,
		Scale = 0.6,
		Color = ColorSequence.new(Color3.fromHex("#FFB800"), Color3.fromHex("#FF5F0F")),
		OnlyMobile = true,
		Enabled = true,
		Draggable = true,
	},
	Topbar = {
		Height = 44,
		ButtonsType = "Mac",
	},
})

if typeof(STATE) == "table" and STATE.onCleanup then
	STATE.onCleanup(function()
		pcall(function()
			Window:Destroy()
		end)
		if FlyBV and FlyBV.Parent then
			FlyBV:Destroy()
		end
		FlyBV = nil
	end)
end

local FarmTab = Window:Tab({
	Title = "Farm",
	Icon = "egg",
})

local AutoSection = FarmTab:Section({
	Title = "Automation",
	Icon = "settings",
})

AutoSection:Toggle({
	Title = "Anti AFK",
	Desc = "Prevents idle kick / auto rejoin",
	Icon = "shield",
	Value = true,
	Callback = function(v)
		flags.antiAfk = v
	end,
})

AutoSection:Space()

AutoSection:Toggle({
	Title = "Auto Collect Eggs",
	Desc = "Collects every egg on your plot",
	Icon = "egg",
	Value = false,
	Callback = function(v)
		flags.autoCollect = v
	end,
})

AutoSection:Space()

AutoSection:Toggle({
	Title = "Aura Collect",
	Desc = "Collects eggs around you",
	Icon = "radar",
	Value = false,
	Callback = function(v)
		flags.auraCollect = v
	end,
})

AutoSection:Space()

AutoSection:Slider({
	Title = "Aura Radius",
	Desc = "Collection range in studs",
	Value = { Min = 10, Max = 150, Default = 30 },
	Step = 5,
	Callback = function(v)
		flags.auraRadius = v
	end,
})

AutoSection:Space()

AutoSection:Toggle({
	Title = "Auto Collect Money",
	Desc = "Collects ready cash automatically",
	Icon = "banknote",
	Value = false,
	Callback = function(v)
		flags.autoMoney = v
	end,
})

FarmTab:Space()

local ProgressSection = FarmTab:Section({
	Title = "Progression",
	Icon = "trending-up",
})

ProgressSection:Toggle({
	Title = "Auto Rebirth",
	Desc = "Rebirths as soon as you can afford it",
	Icon = "refresh-cw",
	Value = false,
	Callback = function(v)
		flags.autoRebirth = v
	end,
})

ProgressSection:Space()

ProgressSection:Slider({
	Title = "Min Rebirth Boost",
	Desc = "Only rebirth when the next boost is at least this (x1 - x350)",
	Value = { Min = 1, Max = 350, Default = 1 },
	Step = 1,
	Callback = function(v)
		flags.rebirthMult = v
	end,
})

ProgressSection:Space()

ProgressSection:Toggle({
	Title = "Auto Buy Chickens",
	Desc = "Buys chickens when you can afford them",
	Icon = "shopping-bag",
	Value = false,
	Callback = function(v)
		flags.autoBuy = v
	end,
})

ProgressSection:Space()

ProgressSection:Dropdown({
	Title = "Buy Amount",
	Values = { "1", "5", "25", "100" },
	Value = "25",
	Callback = function(v)
		flags.buyAmount = tonumber(v)
	end,
})

ProgressSection:Space()

ProgressSection:Toggle({
	Title = "Auto Merge",
	Desc = "Merges chickens when 3+ of a tier are ready",
	Icon = "layers",
	Value = false,
	Callback = function(v)
		flags.autoMerge = v
	end,
})

FarmTab:Space()

local LuckySection = FarmTab:Section({
	Title = "Lucky Blocks",
	Icon = "gift",
})

LuckySection:Toggle({
	Title = "Auto Collect Lucky Blocks",
	Desc = "Claims lucky blocks that drop on your plot",
	Icon = "gift",
	Value = false,
	Callback = function(v)
		flags.autoBlocks = v
	end,
})

LuckySection:Space()

LuckySection:Toggle({
	Title = "Auto Open Lucky Blocks",
	Desc = "Opens the equipped block only if you can afford it",
	Icon = "package",
	Value = false,
	Callback = function(v)
		flags.autoOpen = v
	end,
})

LuckySection:Space()

LuckySection:Toggle({
	Title = "Auto Discard Unaffordable",
	Desc = "Discards the equipped block when you can't afford to open it",
	Icon = "trash",
	Value = false,
	Callback = function(v)
		flags.autoDiscard = v
	end,
})

FarmTab:Space()

local StatsSection = FarmTab:Section({
	Title = "Live Stats",
	Icon = "activity",
})

local StatsParagraph = StatsSection:Paragraph({
	Title = "Loading...",
	Desc = "",
	TextSize = 15,
})

task.spawn(function()
	pcall(setthreadcontext, 8)
	while IsAlive() do
		local ok, err = pcall(function()
			local eggs = GetStat("Eggs") or 0
			local cash = GetStat("CashCollect") or 0
			local proc = GetStat("EggsProcessing") or 0
			StatsParagraph:SetTitle(("Eggs: %s  |  Multiplier: x%.2f"):format(fmt(eggs), MultiplierValue.Value))
			StatsParagraph:SetDesc(("Cash ready: $%s  |  Processing: %s"):format(fmt(cash), fmt(proc)))
		end)
		if not ok then
			warn("[CFH stats] " .. tostring(err))
		end
		task.wait(1)
	end
end)

local SellTab = Window:Tab({
	Title = "Sell",
	Icon = "coins",
})

local SellSection = SellTab:Section({
	Title = "Auto Sell",
	Icon = "shopping-cart",
})

SellSection:Toggle({
	Title = "Auto Sell",
	Desc = "Deposits eggs to be sold. Pair with Auto Collect Eggs.",
	Icon = "shopping-cart",
	Value = false,
	Callback = function(v)
		flags.autoSell = v
	end,
})

SellSection:Space()

SellSection:Slider({
	Title = "Sell Multiplier",
	Desc = "Only sells when the egg multiplier is at or above this (1x - 1.5x)",
	Value = { Min = 1, Max = 1.5, Default = 1.2 },
	Step = 0.05,
	IsTooltip = true,
	Callback = function(v)
		flags.sellMult = v
	end,
})

local ServerTab = Window:Tab({
	Title = "Server",
	Icon = "globe",
})

local ServerSection = ServerTab:Section({
	Title = "Server",
	Icon = "globe",
})

ServerSection:Toggle({
	Title = "Auto Rejoin",
	Desc = "Hop to a new server instead of being kicked",
	Icon = "refresh-cw",
	Value = false,
	Callback = function(v)
		flags.autoRejoin = v
	end,
})

ServerSection:Space()

ServerSection:Button({
	Title = "Rejoin Server",
	Justify = "Center",
	Icon = "log-in",
	Callback = function()
		rejoinServer()
	end,
})

ServerSection:Space()

ServerSection:Button({
	Title = "Server Hop",
	Justify = "Center",
	Icon = "shuffle",
	Callback = function()
		serverHop()
	end,
})

ServerTab:Space()

local RewardSection = ServerTab:Section({
	Title = "Rewards",
	Icon = "gift",
})

RewardSection:Toggle({
	Title = "Auto Claim Group Reward",
	Desc = "Claims the group reward every 10 minutes if you're in a group",
	Icon = "users",
	Value = false,
	Callback = function(v)
		flags.autoGroupReward = v
	end,
})

RewardSection:Space()

RewardSection:Toggle({
	Title = "Auto Claim Offline Earnings",
	Desc = "Claims offline eggs as soon as they appear",
	Icon = "bed",
	Value = false,
	Callback = function(v)
		flags.autoOfflineEarnings = v
	end,
})

ServerTab:Space()

local CodeSection = ServerTab:Section({
	Title = "Codes",
	Icon = "key",
})

local CodeInput = CodeSection:Input({
	Title = "Codes",
	Desc = "Separate multiple codes with commas",
	Placeholder = "CODE1, CODE2",
	Value = "",
	Callback = function(v)
		local parsed = {}
		for c in (v or ""):gmatch("[^,%s]+") do
			table.insert(parsed, c)
		end
		flags.codes = parsed
	end,
})

CodeSection:Space()

CodeSection:Toggle({
	Title = "Auto Redeem Codes",
	Desc = "Redeems the codes above on a timer",
	Icon = "key",
	Value = false,
	Callback = function(v)
		flags.autoCodes = v
	end,
})

CodeSection:Space()

CodeSection:Slider({
	Title = "Redeem Interval",
	Desc = "Seconds between code redemption attempts",
	Value = { Min = 15, Max = 300, Default = 30 },
	Step = 5,
	Callback = function(v)
		flags.codeInterval = v
	end,
})

local MoveTab = Window:Tab({
	Title = "Movement",
	Icon = "gauge",
})local MoveSection = MoveTab:Section({
	Title = "Movement",
	Icon = "gauge",
})

MoveSection:Toggle({
	Title = "Walk Speed",
	Desc = "Overrides your walking speed",
	Icon = "footprints",
	Value = false,
	Callback = function(v)
		flags.walkSpeed = v
		if not v then
			applyWalkSpeed()
		end
	end,
})

MoveSection:Space()

MoveSection:Slider({
	Title = "Speed",
	Value = { Min = 16, Max = 200, Default = 16 },
	Step = 1,
	Callback = function(v)
		flags.walkSpeedVal = v
		if flags.walkSpeed then
			applyWalkSpeed()
		end
	end,
})

MoveSection:Space()

MoveSection:Toggle({
	Title = "Fly",
	Desc = "WASD to move, Space / Ctrl for up and down",
	Icon = "rocket",
	Value = false,
	Callback = function(v)
		flags.fly = v
		if not v then
			local char = LocalPlayer.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.PlatformStand = false
			end
		end
	end,
})

MoveSection:Space()

MoveSection:Slider({
	Title = "Fly Speed",
	Value = { Min = 10, Max = 200, Default = 50 },
	Step = 5,
	Callback = function(v)
		flags.flySpeed = v
	end,
})

local UITab = Window:Tab({
	Title = "UI",
	Icon = "settings",
})

local UISection = UITab:Section({
	Title = "Settings",
	Icon = "settings",
})

UISection:Keybind({
	Title = "Open / Close Key",
	Desc = "Ctrl by default",
	Value = "LeftControl",
	Callback = function(k)
		Window:SetToggleKey(Enum.KeyCode[k])
	end,
})

UISection:Space()

UISection:Button({
	Title = "Destroy Hub",
	Color = Color3.fromHex("#ff4830"),
	Justify = "Center",
	Icon = "trash",
	Callback = function()
		Window:Destroy()
	end,
})

WindUI:Notify({
	Title = "Chicken Farm Hub",
	Content = "Loaded! Toggle UI with Ctrl",
	Icon = "egg",
	Duration = 4,
})
