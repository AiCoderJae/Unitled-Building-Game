-- -- ServerSCriptService/Server/PlacementService.lua
-- Integrates PlotManager so each player's blocks are placed inside their own plot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local GridUtil = require(ReplicatedStorage.Shared.Modules.GridUtil)
local PlotManager = require(ServerScriptService:WaitForChild("Server"):WaitForChild("PlotManager"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlaceBlockEvent = Remotes:WaitForChild("PlaceBlock")

local BlockAssets = ReplicatedStorage:WaitForChild("BlockAssets")
local BlockTemplates = BlockAssets:WaitForChild("BlockTemplates")
local BlockPalette = BlockAssets:FindFirstChild("BlockPalette")

local fallbackPlacedFolder = Workspace:FindFirstChild("PlacedBlocks") or (function()
	local f = Instance.new("Folder")
	f.Name = "PlacedBlocks"
	f.Parent = Workspace
	return f
end)()

local function resolveTemplateByName(name)
        if type(name) == "string" and #name > 0 then
                return BlockTemplates:FindFirstChild(name)
        end
        return nil
end

local function spawnFromTemplate(tpl)
        if tpl:IsA("BasePart") then return tpl:Clone() end
        if tpl:IsA("Model") and tpl.PrimaryPart then return tpl.PrimaryPart:Clone() end

	local p = Instance.new("Part")
	p.Size = Vector3.new(GridUtil.BLOCK_SIZE, GridUtil.BLOCK_SIZE, GridUtil.BLOCK_SIZE)
	return p
end

local function clearTextures(part)
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("Texture") then child:Destroy() end
	end
end

local function applyVisuals(part, visual)
	if not part or not visual then return end

	if visual.Color then part.Color = visual.Color end

	if visual.Material then
		local ok, mat = pcall(function()
			return typeof(visual.Material) == "EnumItem" and visual.Material or Enum.Material[visual.Material]
		end)
		if ok and mat then part.Material = mat end
	end

	if visual.MaterialVariant and type(visual.MaterialVariant) == "string" then
		pcall(function()
			part.MaterialVariant = visual.MaterialVariant
		end)
	end

	if typeof(visual.Reflectance) == "number" then
		part.Reflectance = visual.Reflectance
	end

	clearTextures(part)

	if visual.TextureId and visual.TextureId ~= "" then
		local u = visual.StudsPerTileU or 4
		local v = visual.StudsPerTileV or 4

		for _, face in ipairs(Enum.NormalId:GetEnumItems()) do
			local tx = Instance.new("Texture")
			tx.Texture = visual.TextureId
			tx.Face = face
			tx.StudsPerTileU = u
			tx.StudsPerTileV = v
			tx.Parent = part
		end
	end
end

local function isInsidePlot(targetCf, boundary)
	if not boundary or not targetCf then return false end

	local worldPos = targetCf.Position

	-- Convert world position into boundary's local space
	local localCf = boundary.CFrame:Inverse() * CFrame.new(worldPos)
	local localPos = localCf.Position
	local halfSize = boundary.Size * 0.5

	-- Only care about X/Z (top-down), ignore Y completely
	local withinX = math.abs(localPos.X) <= halfSize.X + 0.01
	local withinZ = math.abs(localPos.Z) <= halfSize.Z + 0.01

	return withinX and withinZ
end

PlaceBlockEvent.OnServerEvent:Connect(function(plr, blockId, cf, sourceInstance, visualSpec, rotationY)
        local plotModel = PlotManager.GetPlayerPlot(plr)
        if not plotModel then
                warn(("[Placement] %s has no assigned plot; blocking placement."):format(plr.Name))
                return
        end

        local boundary = plotModel:FindFirstChild("PlotBoundary")
        local blocksFolder = plotModel:FindFirstChild("PlayerPlacedBlocks")

	if not blocksFolder then
		warn(("[Placement] Plot for %s missing PlayerPlacedBlocks; using fallback."):format(plr.Name))
		blocksFolder = fallbackPlacedFolder
	end
        -- Hard Y caps: keep placements within play space
        if cf.Position.Y > 122 then
                warn(("[Placement] %s attempted to place above Y cap; blocked."):format(plr.Name))
                return
        end
        local minY = GridUtil.ORIGIN.Y + (GridUtil.BLOCK_SIZE * 0.5)
        if cf.Position.Y < minY then
                warn(("[Placement] %s attempted to place below floor; blocked."):format(plr.Name))
                return
        end

        if boundary and not isInsidePlot(cf, boundary) then
                warn(("[Placement] %s attempted to place outside plot bounds; blocked."):format(plr.Name))
                return
        end

        local tpl = nil
        if sourceInstance then
                local paletteAllowed = BlockPalette and sourceInstance:IsDescendantOf(BlockPalette)
                local templateAllowed = sourceInstance:IsDescendantOf(BlockTemplates)

                if paletteAllowed or templateAllowed then
                        tpl = sourceInstance
                end
        end
        if not tpl and visualSpec and visualSpec.TemplateName then
                tpl = resolveTemplateByName(visualSpec.TemplateName)
        end
        if not tpl then
                tpl = resolveTemplateByName("Block_4x4x4")
        end

        if not tpl then
                warn(("[Placement] %s attempted to place unknown template; blocked."):format(plr.Name))
                return
        end

        local part = spawnFromTemplate(tpl)
        if not part then
                warn(("[Placement] %s failed to spawn block; blocked."):format(plr.Name))
                return
        end
        part.Anchored = true
        part.CanCollide = true
        part.Name = "Block"

        local yaw = tonumber(rotationY) or 0
        part.CFrame = cf * CFrame.Angles(0, math.rad(yaw), 0)

        applyVisuals(part, visualSpec)

        part.Parent = blocksFolder
        CollectionService:AddTag(part, "PlacedBlock")
end)
