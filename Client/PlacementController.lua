-- PlacementControllerv2_polishG_visuals.client.lua (patched for rotation)
-- Adds R-key rotation in 90 degree steps (modifiable) for ghost + placed blocks.
-- Keeps all prior visuals logic and snapping, but fixes Y snapping + model height mismatches.

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
-- Flip state (vertical flip as 180° around X)
local currentFlipX = 0 -- degrees (0 or 180)

-- Helpers
local function resolveTemplateByName(name: string?): Instance?
	if type(name) == "string" and #name > 0 then
		return BlockTemplates:FindFirstChild(name)
	end
	return nil
end

local function getTemplateFor(): Instance?
	if currentSourceInstance and currentSourceInstance:IsDescendantOf(BlockAssets) then
		return currentSourceInstance
	end
	return resolveTemplateByName("Block_4x4x4")
end

-- IMPORTANT: measure height in a way that matches what we actually clone for the ghost
local function measureTemplateHeight(inst: Instance?): number
	if not inst then
		return GridUtil.BLOCK_SIZE
	end

	if inst:IsA("BasePart") then
		return inst.Size.Y
	end

	if inst:IsA("Model") then
		-- Prefer PrimaryPart since createGhost() clones PrimaryPart
		if inst.PrimaryPart and inst.PrimaryPart:IsA("BasePart") then
			return inst.PrimaryPart.Size.Y
		end
		-- Fallback if no primary part
		return inst:GetExtentsSize().Y
	end

	return GridUtil.BLOCK_SIZE
end

local function isTextInputFocused(): boolean
	return UserInputService:GetFocusedTextBox() ~= nil
end

local function clearTextures(part: Instance)
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("Texture") then
			child:Destroy()
		end
	end
end

local function applyVisualsToPart(part: BasePart, visual: table?)
	if not part or not visual then
		return
	end

	if visual.Color then
		part.Color = visual.Color
	end

	if visual.Material then
		local ok, mat = pcall(function()
			return typeof(visual.Material) == "EnumItem" and visual.Material or Enum.Material[visual.Material]
		end)
		if ok and mat then
			part.Material = mat
		end
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
	if previewPart and previewPart.Parent then
		return previewPart
	end

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
	if previewPart then
		previewPart:Destroy()
		previewPart = nil
	end
	ghostActive = false
end

-- Raycast filter
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = {}

local function rebuildRayFilter()
	local list = {}
	if LocalPlayer.Character then
		table.insert(list, LocalPlayer.Character)
	end
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

-- Snap Y to valid centers.
-- Full blocks use 4-stud layers; slabs use 2-stud layers (half-block).
local function snapCenterY(yWorld: number, height: number): number
	local s = GridUtil.BLOCK_SIZE
	local oY = GridUtil.ORIGIN.Y

	local step = s
	if height < s - 1e-3 then
		step = s * 0.5
	end

	-- nearest center index
	local t = (yWorld - (oY + step * 0.5)) / step
	local idx = math.floor(t + 0.5)

	return oY + (idx + 0.5) * step
end

-- Rotation input (R key to rotate +90°)
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end

	if input.KeyCode == Enum.KeyCode.R then
		currentRotationY = (currentRotationY + rotationStep) % 360
	elseif input.KeyCode == Enum.KeyCode.Q then
		currentFlipX = (currentFlipX == 0) and 180 or 0
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

	-- Base snapped center via GridUtil (X/Z correct)
	local center = GridUtil.GetPlacementCenter(result)
	local normal = result.Normal

	-- Height-aware snapping
	lastTemplateHeight = measureTemplateHeight(getTemplateFor())

	local yHit = result.Position.Y
	if math.abs(normal.Y) > 0.5 then
		-- placing onto top/bottom faces: offset by half height, then snap to valid layer centers
		local desiredY = yHit + (lastTemplateHeight * 0.5)
		center = Vector3.new(center.X, snapCenterY(desiredY, lastTemplateHeight), center.Z)
	else
		-- placing against a side face: use hit height and snap to a valid center (block or slab layers)
		center = Vector3.new(center.X, snapCenterY(yHit, lastTemplateHeight), center.Z)
	end

	-- Prevent sinking below the build origin plane
	local floorY = GridUtil.ORIGIN.Y + (lastTemplateHeight * 0.5)
	if center.Y < floorY then
		center = Vector3.new(center.X, floorY, center.Z)
	end

	lastPlacedCenter = center
	local effectiveYaw =
		(currentFlipX == 180)
		and currentRotationY
		or -currentRotationY

	local targetCF =
		CFrame.new(center)
		* CFrame.Angles(
			math.rad(currentFlipX),
			math.rad(effectiveYaw),
			0
		)
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

	PlaceBlockEvent:FireServer(
		currentBlockId,
		CFrame.new(lastPlacedCenter),
		currentSourceInstance,
		currentVisual,
		currentRotationY,
		currentFlipX
	)
end)

SetBlockIdBE.Event:Connect(function(blockId: string?, spec)
	-- When blockId is nil, we treat this as "no block in hand"
	if blockId == nil then
		currentBlockId = nil
		currentSourceInstance = nil
		currentVisual = nil
		lastTemplateHeight = GridUtil.BLOCK_SIZE
		-- reset orientation state
		currentRotationY = 0
		currentFlipX = 0
		destroyGhost()
		return
	end

	-- Equip a specific block id
	currentBlockId = blockId
	currentSourceInstance = nil
	currentVisual = nil
	-- reset orientation state per block equip
	currentRotationY = 0
	currentFlipX = 0
	
	if spec then
		-- Highest priority: explicit instance
		if spec.SourceInstance then
			currentSourceInstance = spec.SourceInstance
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
