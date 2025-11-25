-- PlacementControllerv2_polishG_visuals.client.lua (patched for rotation)
-- Adds R-key rotation in 90 degree steps(modifiable) for ghost + placed blocks.
-- Keeps all prior visuals logic and side-face snapping.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()

local GridUtil = require(ReplicatedStorage.Shared.Modules.GridUtil)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlaceBlockEvent = Remotes:WaitForChild("PlaceBlock")
local SetBlockIdBE = Remotes:WaitForChild("SetBlockId") :: BindableEvent

local BlockAssets = ReplicatedStorage:WaitForChild("BlockAssets")
local BlockTemplates = BlockAssets:WaitForChild("BlockTemplates")

local SHOW_DIST = 40
local HIDE_DIST = 50
local PREVIEW_TRANSPARENCY = 0.85
local PREVIEW_VALID_COLOR = Color3.fromRGB(255, 255, 255)

local currentBlockId: string? = nil
local currentSourceInstance: Instance? = nil
local currentVisual: table? = nil

local previewPart: BasePart? = nil
local ghostActive = false
local lastPlacedCenter: Vector3? = nil
local lastTemplateHeight = GridUtil.BLOCK_SIZE -- fallback

-- Rotation state
local rotationStep = 90
local currentRotationY = 0 -- degrees

-- Helpers
local function resolveTemplateByName(name: string?): Instance?
	if type(name) == "string" and #name > 0 then return BlockTemplates:FindFirstChild(name) end
	return nil
end

local function getTemplateFor(): Instance?
        if currentSourceInstance and currentSourceInstance:IsDescendantOf(BlockAssets) then
                return currentSourceInstance
        end
        return resolveTemplateByName("Block_4x4x4")
end

local function measureTemplateHeight(inst: Instance?): number
	if not inst then return GridUtil.BLOCK_SIZE end
	if inst:IsA("BasePart") then return inst.Size.Y end
	if inst:IsA("Model") then
		local size = inst:GetExtentsSize()
		return size.Y
	end
	return GridUtil.BLOCK_SIZE
end

local function isTextInputFocused(): boolean
        local focused = UserInputService:GetFocusedTextBox()
        return focused ~= nil
end

local function clearTextures(part: Instance)
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("Texture") then child:Destroy() end
	end
end

local function applyVisualsToPart(part: BasePart, visual: table?)
	if not part or not visual then return end
	if visual.Color then part.Color = visual.Color end
	if visual.Material then
		local ok, mat = pcall(function()
			return typeof(visual.Material) == "EnumItem" and visual.Material or Enum.Material[visual.Material]
		end)
		if ok and mat then part.Material = mat end
	end
	-- Apply MaterialVariant AFTER Material so Roblox accepts the pairing
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

local function createGhost()
	if previewPart and previewPart.Parent then return previewPart end

	local tpl = getTemplateFor()
	lastTemplateHeight = measureTemplateHeight(tpl)

	if tpl and tpl:IsA("Model") and tpl.PrimaryPart then
		previewPart = tpl.PrimaryPart:Clone()
	elseif tpl and tpl:IsA("BasePart") then
		previewPart = tpl:Clone()
	else
		previewPart = Instance.new("Part")
		previewPart.Size = Vector3.new(GridUtil.BLOCK_SIZE, GridUtil.BLOCK_SIZE, GridUtil.BLOCK_SIZE)
		lastTemplateHeight = previewPart.Size.Y
	end

	previewPart.Anchored = true
	previewPart.CanCollide = false
	previewPart.CanQuery = false
	previewPart.CanTouch = false
	previewPart.Transparency = PREVIEW_TRANSPARENCY
	previewPart.Name = "BuildPreview"
	previewPart.Parent = Workspace
	CollectionService:AddTag(previewPart, "BuildPreview")

	-- Apply visuals (color kept if none provided)
	if currentVisual then
		applyVisualsToPart(previewPart, currentVisual)
	else
		previewPart.Color = PREVIEW_VALID_COLOR
	end
	return previewPart
end

local function destroyGhost()
	if previewPart then previewPart:Destroy(); previewPart = nil end
	ghostActive = false
end

-- Raycast filter
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = {}
local function rebuildRayFilter()
	local list = {}
	if LocalPlayer.Character then table.insert(list, LocalPlayer.Character) end
	for _, inst in ipairs(CollectionService:GetTagged("BuildPreview")) do
		table.insert(list, inst)
	end
	rayParams.FilterDescendantsInstances = list
end

-- Smoothing
local function smoothStep(current: CFrame, target: CFrame, dt: number, stiffness: number)
	local alpha = 1 - math.exp(-stiffness * dt)
	return current:Lerp(target, alpha)
end

-- Side-face vertical snapping
local function sideFaceY(result: RaycastResult, height: number): number
	local s = GridUtil.BLOCK_SIZE
	local oY = GridUtil.ORIGIN.Y
	local yWorld = result.Position.Y
	local cellY = math.floor((yWorld - oY) / s)
	local midY = oY + (cellY + 0.5) * s

	if height >= s - 1e-3 then
		return midY -- full block: center of the 4-stud cell
	else
		local lowerCenter = oY + cellY * s + (height * 0.5)
		local upperCenter = oY + (cellY + 1) * s - (height * 0.5)
		if yWorld >= midY then return upperCenter else return lowerCenter end
	end
end

-- Rotation input (R key to rotate +45°)
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.R then
		currentRotationY = (currentRotationY + rotationStep) % 360
	end
end)

RunService.RenderStepped:Connect(function(dt)
        -- Ignore all placement visuals while typing/chatting so we don't capture mouse rays
        if isTextInputFocused() then
                destroyGhost()
                lastPlacedCenter = nil
                return
        end

        -- If no block is equipped, we don't show or update the ghost at all.
        if not currentBlockId then
                destroyGhost()
                lastPlacedCenter = nil
                return
	end

	rebuildRayFilter()

        local unitRay = Mouse.UnitRay
        if not unitRay then
                destroyGhost()
                lastPlacedCenter = nil
                return
        end
        local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * HIDE_DIST, rayParams)

        if not result then
                destroyGhost()
                lastPlacedCenter = nil
		return
	end

	local dist = (result.Position - unitRay.Origin).Magnitude
	if (not ghostActive) and dist > SHOW_DIST then
		destroyGhost()
		lastPlacedCenter = nil
		return
	end

	-- Base snapped center via GridUtil
	local center = GridUtil.GetPlacementCenter(result)
	local normal = result.Normal

	-- Height-aware Y handling
	lastTemplateHeight = measureTemplateHeight(getTemplateFor())
	if math.abs(normal.Y) > 0.5 then
		center = Vector3.new(center.X, result.Position.Y + (lastTemplateHeight * 0.5), center.Z)
	else
		center = Vector3.new(center.X, sideFaceY(result, lastTemplateHeight), center.Z)
	end

        -- Prevent sinking below the build origin plane
        local floorY = GridUtil.ORIGIN.Y + (lastTemplateHeight * 0.5)
        if center.Y < floorY then
                center = Vector3.new(center.X, floorY, center.Z)
        end

        lastPlacedCenter = center
	local targetCF = CFrame.new(center) * CFrame.Angles(0, math.rad(currentRotationY), 0)

	local ghost = createGhost()
	if not ghostActive then
		ghost.CFrame = targetCF
		ghostActive = true
	else
		local currentPos = ghost.CFrame.Position
		if (currentPos - center).Magnitude > (GridUtil.BLOCK_SIZE * 3) then
			ghost.CFrame = targetCF
		else
			ghost.CFrame = smoothStep(ghost.CFrame, targetCF, dt, 12)
		end
	end
end)

Mouse.Button1Down:Connect(function()
        if isTextInputFocused() then return end
        if not currentBlockId then return end
        if not lastPlacedCenter then return end
        PlaceBlockEvent:FireServer(currentBlockId, CFrame.new(lastPlacedCenter), currentSourceInstance, currentVisual, currentRotationY)
end)

SetBlockIdBE.Event:Connect(function(blockId: string?, spec)
	-- When blockId is nil, we treat this as "no block in hand"
	if blockId == nil then
		currentBlockId = nil
		currentSourceInstance = nil
		currentVisual = nil
		lastTemplateHeight = GridUtil.BLOCK_SIZE
		destroyGhost()
		return
	end

	-- Equip a specific block id
	currentBlockId = blockId
	currentSourceInstance = nil
	currentVisual = nil

	if spec then
		-- Highest priority: explicit instance
		if spec.SourceInstance then
			currentSourceInstance = spec.SourceInstance
			-- Fallback: resolve by template name
		elseif spec.TemplateName then
			currentSourceInstance = resolveTemplateByName(spec.TemplateName)
		end

		-- Visuals (Color, Material, MaterialVariant, TextureId, etc.)
		currentVisual = spec.Visual
	end

	-- Recreate the ghost so geometry + textures update instantly
	if previewPart then
		destroyGhost()
		createGhost()
	end
end)

