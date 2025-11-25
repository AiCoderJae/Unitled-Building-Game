-- ServerSCriptService/Server/PlotManager.lua
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotManager = {}

--// CONFIG
local PLOTS_FOLDER_NAME = "PlayerPlots"
local TEMPLATE_ATTRIBUTE = "IsTemplate" -- mark true on any model you DON'T want used as a live plot
local HEADSHOT_TEMPLATE_PATH = { "ReplicatingAssets", "HeadshotTemplate" }

--// INTERNAL
local plotsFolder = Workspace:WaitForChild(PLOTS_FOLDER_NAME)

-- [plotModel] = { PlotID = number, Claimed = bool, Owner = Player? }
local plotPool: {[Model]: {PlotID: number, Claimed: boolean, Owner: Player?}} = {}
-- [player] = plotModel
local playerToPlot: {[Player]: Model} = {}

local headshotTemplate: BillboardGui? = nil

--// UTIL

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
	local template = resolveHeadshotTemplate()
	if not template then
		return
	end

	local boundary = plotModel:FindFirstChild("PlotBoundary")
	if not (boundary and boundary:IsA("BasePart")) then
		warn(("[PlotManager] Plot %s is missing a valid PlotBoundary for headshot GUI"):format(plotModel.Name))
		return
	end

	local attachment = boundary:FindFirstChild("HeadshotAttachment")
	if not (attachment and attachment:IsA("Attachment")) then
		warn(("[PlotManager] Plot %s is missing HeadshotAttachment on PlotBoundary"):format(plotModel.Name))
		return
	end

	-- Remove any existing headshot GUI
	clearHeadshotGui(plotModel)

	local newGui = template:Clone()
	newGui:SetAttribute("IsHeadshotGui", true)
	newGui.Parent = attachment

	-- Drill into the expected structure:
	-- BillboardGui -> Frame -> ImageFrame, NameFrame
	local rootFrame = newGui:FindFirstChild("Frame")
	if not (rootFrame and rootFrame:IsA("Frame")) then
		return
	end

	local imageFrame = rootFrame:FindFirstChild("ImageFrame")
	local nameFrame = rootFrame:FindFirstChild("NameFrame")

	local imageLabel: ImageLabel? = nil
	if imageFrame and imageFrame:IsA("Frame") then
		imageLabel = imageFrame:FindFirstChildWhichIsA("ImageLabel")
	end

	local nameLabel: TextLabel? = nil
	if nameFrame and nameFrame:IsA("Frame") then
		nameLabel = nameFrame:FindFirstChildWhichIsA("TextLabel")
	end

	-- Set player name
	if nameLabel then
		nameLabel.Text = player.DisplayName or player.Name
	end

	-- Set player headshot
	if imageLabel then
		local success, content = pcall(function()
			return Players:GetUserThumbnailAsync(
				player.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size100x100
			)
		end)

		if success and content then
			imageLabel.Image = content
		else
			warn(("[PlotManager] Failed to get thumbnail for %s"):format(player.Name))
		end
	end
end

-- Register all manually placed plots in Workspace.PlayerPlots
local function registerPlots()
	local nextId = 1

	for _, child in ipairs(plotsFolder:GetChildren()) do
		if child:IsA("Model") then
			-- Skip any models explicitly marked as templates
			if not child:GetAttribute(TEMPLATE_ATTRIBUTE) then
				local boundary = child:FindFirstChild("PlotBoundary")
				local blocksFolder = child:FindFirstChild("PlayerPlacedBlocks")

				if boundary and boundary:IsA("BasePart") and blocksFolder and blocksFolder:IsA("Folder") then
					local existingId = child:GetAttribute("PlotID")
					local plotId = existingId or nextId

					-- If there was no PlotID, assign one
					if not existingId then
						child:SetAttribute("PlotID", plotId)
					end

					child:SetAttribute("Claimed", false)
					child:SetAttribute("OwnerUserId", nil)

					plotPool[child] = {
						PlotID = plotId,
						Claimed = false,
						Owner = nil,
					}

					nextId += 1
				else
					warn(("[PlotManager] Model %s in %s is missing PlotBoundary or PlayerPlacedBlocks; skipping.")
						:format(child.Name, PLOTS_FOLDER_NAME))
				end
			end
		end
	end

	if nextId == 1 then
		warn("[PlotManager] No valid plot models found in Workspace.PlayerPlots. Did you set them up?")
	end
end

--// API

function PlotManager.GetPlayerPlot(player: Player): Model?
	return playerToPlot[player]
end

function PlotManager.AssignPlot(player: Player): Model?
	-- If already assigned, just return
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

			-- Add visual ownership marker
			applyHeadshotGui(plotModel, player)

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

	local data = plotPool[plotModel]
	if data then
		data.Claimed = false
		data.Owner = nil
	end

	plotModel:SetAttribute("Claimed", false)
	plotModel:SetAttribute("OwnerUserId", nil)

	-- Clear all placed blocks on release (you'll hook DataStore loading/saving later)
	local blocksFolder = plotModel:FindFirstChild("PlayerPlacedBlocks")
	if blocksFolder then
		blocksFolder:ClearAllChildren()
	end

	-- Remove visual ownership marker
	clearHeadshotGui(plotModel)

	playerToPlot[player] = nil
	player:SetAttribute("PlotID", nil)
end

--// LIFECYCLE HOOKS

Players.PlayerAdded:Connect(function(player)
	PlotManager.AssignPlot(player)
end)

Players.PlayerRemoving:Connect(function(player)
	PlotManager.ReleasePlot(player)
end)

registerPlots()

return PlotManager
