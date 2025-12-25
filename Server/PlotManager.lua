-- ServerScriptService/Server/PlotManager.lua
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BuildStateService = require(ServerScriptService.Server.BuildStateService)
local BuildStore = require(ServerScriptService.Server.BuildStore)

-- DataStore name/version. Change this if you ever make a breaking record-format change.
local BUILDSTORE_NAME = "PlayerBuilds_v1"
local buildStore = BuildStore.new(BUILDSTORE_NAME)

local PlotManager = {}

--// CONFIG
local PLOTS_FOLDER_NAME = "PlayerPlots"
local TEMPLATE_ATTRIBUTE = "IsTemplate" -- mark true on any model you DON'T want used as a live plot
local HEADSHOT_TEMPLATE_PATH = { "ReplicatingAssets", "HeadshotTemplate" }

--// STATE
local plotPool: {[Model]: {PlotID: number, Claimed: boolean, Owner: Player?}} = {}
local playerToPlot: {[Player]: Model} = {}

--// TEMPLATE RESOLVING (shape templates)
local templateCache: {[string]: Instance} = {}

local function findTemplateRoots(): {Instance}
	local roots = {}

	local function add(path: {string})
		local node: Instance? = ReplicatedStorage
		for _, name in ipairs(path) do
			node = node and node:FindFirstChild(name)
		end
		if node then table.insert(roots, node) end
	end

	add({ "BlockAssets", "BlockTemplates" })
	add({ "BlockTemplates" })

	return roots
end

local function resolveTemplate(templateName: any): Instance?
	local key = tostring(templateName)
	if templateCache[key] then
		return templateCache[key]
	end

	for _, root in ipairs(findTemplateRoots()) do
		local byName = root:FindFirstChild(key)
		if byName then
			templateCache[key] = byName
			return byName
		end
	end

	-- Last resort: scan for Attribute BlockId match
	for _, root in ipairs(findTemplateRoots()) do
		for _, inst in ipairs(root:GetDescendants()) do
			local bid = inst:GetAttribute("BlockId")
			if tostring(bid) == key then
				templateCache[key] = inst
				return inst
			end
		end
	end

	warn(("[PlotManager] Missing template for templateName='%s' (cannot load this record)"):format(key))
	return nil
end

--// HEADSHOT GUI
local headshotTemplate: BillboardGui? = nil

local function resolveHeadshotTemplate(): BillboardGui?
	if headshotTemplate and headshotTemplate.Parent then
		return headshotTemplate
	end

	local current: Instance = ReplicatedStorage
	for _, name in ipairs(HEADSHOT_TEMPLATE_PATH) do
		local nextInstance = current:FindFirstChild(name)
		if not nextInstance then
			warn(("[PlotManager] Could not find %s while resolving HeadshotTemplate"):format(name))
			return nil
		end
		current = nextInstance
	end

	if current and current:IsA("BillboardGui") then
		headshotTemplate = current
	else
		warn("[PlotManager] HeadshotTemplate is not a BillboardGui")
	end

	return headshotTemplate
end

local function clearHeadshotGui(plotModel: Model)
	local boundary = plotModel:FindFirstChild("PlotBoundary")
	if not (boundary and boundary:IsA("BasePart")) then
		return
	end

	local attachment = boundary:FindFirstChild("HeadshotAttachment")
	if not (attachment and attachment:IsA("Attachment")) then
		return
	end

	for _, child in ipairs(attachment:GetChildren()) do
		if child:IsA("BillboardGui") and child:GetAttribute("IsHeadshotGui") then
			child:Destroy()
		end
	end
end

local function applyHeadshotGui(plotModel: Model, player: Player)
	local boundary = plotModel:FindFirstChild("PlotBoundary")
	if not (boundary and boundary:IsA("BasePart")) then return end

	local attachment = boundary:FindFirstChild("HeadshotAttachment")
	if not (attachment and attachment:IsA("Attachment")) then return end

	local template = resolveHeadshotTemplate()
	if not template then return end

	clearHeadshotGui(plotModel) -- bring back old behavior

	local gui = template:Clone()
	gui:SetAttribute("IsHeadshotGui", true)
	gui.Parent = attachment

	-- Find any labels anywhere (supports both old + new template layouts)
	local imageLabel = gui:FindFirstChildWhichIsA("ImageLabel", true)
	local nameLabel  = gui:FindFirstChildWhichIsA("TextLabel", true)

	if nameLabel then
		nameLabel.Text = player.DisplayName or player.Name
	end

	if imageLabel then
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(
				player.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size150x150
			)
		end)
		if ok and content then
			imageLabel.Image = content
		end
	end
end

--// PLOTS
local function registerPlots()
	local plotsFolder = Workspace:FindFirstChild(PLOTS_FOLDER_NAME)
	if not plotsFolder then
		warn(("[PlotManager] Missing Workspace.%s folder"):format(PLOTS_FOLDER_NAME))
		return
	end

	for _, plotModel in ipairs(plotsFolder:GetChildren()) do
		if plotModel:IsA("Model") and not plotModel:GetAttribute(TEMPLATE_ATTRIBUTE) then
			local plotId = plotModel:GetAttribute("PlotID")
			if typeof(plotId) ~= "number" then
				-- fallback: parse digits from name
				local n = tonumber(string.match(plotModel.Name, "%d+"))
				plotId = n or 0
			end
			plotPool[plotModel] = { PlotID = plotId, Claimed = false, Owner = nil }
		end
	end
end

--// API
function PlotManager.GetPlot(player: Player): Model?
	return playerToPlot[player]
end

function PlotManager.AssignPlot(player: Player): Model?
	if playerToPlot[player] then
		return playerToPlot[player]
	end

	for plotModel, data in pairs(plotPool) do
		if not data.Claimed then
			data.Claimed = true
			data.Owner = player

			plotModel:SetAttribute("Claimed", true)
			plotModel:SetAttribute("OwnerUserId", player.UserId)
			player:SetAttribute("PlotID", data.PlotID)

			playerToPlot[player] = plotModel

			applyHeadshotGui(plotModel, player)

			-- Ensure blocks folder exists
			local blocksFolder = plotModel:FindFirstChild("PlayerPlacedBlocks")
			if not blocksFolder then
				blocksFolder = Instance.new("Folder")
				blocksFolder.Name = "PlayerPlacedBlocks"
				blocksFolder.Parent = plotModel
			end

			-- Bind plot for build tracking
			BuildStateService:BindPlot(player, plotModel)

			-- Load per-player build (works on any plot). If missing, migrate legacy per-plot keys.
			local records = buildStore:Load(player.UserId)
			if not records then
				local found = nil
				for _, d in pairs(plotPool) do
					if d and typeof(d.PlotID) == "number" then
						local legacy = buildStore:LoadLegacy(player.UserId, d.PlotID)
						if legacy and type(legacy) == "table" and #legacy > 0 then
							found = legacy
							break
						end
					end
				end
				if found then
					records = found
					buildStore:Save(player.UserId, records)
				end
			end

			if records then
				blocksFolder:ClearAllChildren()
				BuildStateService:SpawnRecords(player, records, blocksFolder, resolveTemplate)
			end

			return plotModel
		end
	end

	warn(("[PlotManager] No free plots available for %s"):format(player.Name))
	return nil
end

function PlotManager.ReleasePlot(player: Player)
	local plotModel = playerToPlot[player]
	if not plotModel then
		return
	end

	-- Save per-player build before clearing/unbinding
	local snap = BuildStateService:Snapshot(player)
	if snap then
		buildStore:Save(player.UserId, snap)
	end

	-- Clear blocks
	local blocksFolder = plotModel:FindFirstChild("PlayerPlacedBlocks")
	if blocksFolder then
		blocksFolder:ClearAllChildren()
	end

	clearHeadshotGui(plotModel)
	BuildStateService:UnbindPlot(player)

	local data = plotPool[plotModel]
	if data then
		data.Claimed = false
		data.Owner = nil
	end

	plotModel:SetAttribute("Claimed", false)
	plotModel:SetAttribute("OwnerUserId", nil)

	playerToPlot[player] = nil
end

--// LIFECYCLE
Players.PlayerAdded:Connect(function(player)
	PlotManager.AssignPlot(player)
end)

Players.PlayerRemoving:Connect(function(player)
	PlotManager.ReleasePlot(player)
end)

registerPlots()

return PlotManager
