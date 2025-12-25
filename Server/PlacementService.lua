-- ServerScriptService/Server/PlacementService.lua
-- Places blocks inside the player's assigned plot and saves deterministic cell + rotation.
-- Fixes:
-- 1) Uses PlotManager.GetPlot (PlotManager does NOT export GetPlayerPlot)
-- 2) Computes finalCell ONCE and uses it for both snapping and saving (prevents drift)
-- 3) Preserves full rotation (supports flips/wedges) when snapping position

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local GridUtil = require(ReplicatedStorage.Shared.Modules.GridUtil)
local PlotManager = require(ServerScriptService:WaitForChild("Server"):WaitForChild("PlotManager"))
local BuildStateService = require(ServerScriptService:WaitForChild("Server"):WaitForChild("BuildStateService"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlaceBlockEvent = Remotes:WaitForChild("PlaceBlock")
local Notify = Remotes:WaitForChild("Notify")

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

local function spawnFromTemplate(tpl: Instance)
	if tpl:IsA("BasePart") then return tpl:Clone() end
	if tpl:IsA("Model") and tpl.PrimaryPart then return tpl.PrimaryPart:Clone() end

	local p = Instance.new("Part")
	p.Size = Vector3.new(GridUtil.BLOCK_SIZE, GridUtil.BLOCK_SIZE, GridUtil.BLOCK_SIZE)
	return p
end

local function clearTextures(part: BasePart)
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("Texture") then child:Destroy() end
	end
end

local function roundTo(n, step)
	return math.floor(n / step + 0.5) * step
end

local function roundVecTenths(v: Vector3)
	return Vector3.new(
		roundTo(v.X, 0.1),
		roundTo(v.Y, 0.1),
		roundTo(v.Z, 0.1)
	)
end

local function cleanYawDegrees(yaw)
	yaw = math.round(tonumber(yaw) or 0) -- integer degrees
	-- If you ONLY want 90° steps, use this instead:
	-- yaw = (math.round(yaw / 90) * 90) % 360
	return yaw
end

-- OPTIONAL: if your game ONLY uses 90° rotations + flips, this removes tiny float garbage in the basis.
-- Set this true only if you never use arbitrary angles.
local USE_ORTHO_ROTATION_QUANTIZE = false
local function _snapAxis(v: Vector3): Vector3
	local ax = Vector3.new(1,0,0)
	local ay = Vector3.new(0,1,0)
	local az = Vector3.new(0,0,1)

	local dx = v:Dot(ax)
	local dy = v:Dot(ay)
	local dz = v:Dot(az)

	local adx, ady, adz = math.abs(dx), math.abs(dy), math.abs(dz)
	if adx >= ady and adx >= adz then
		return (dx >= 0) and ax or -ax
	elseif ady >= adx and ady >= adz then
		return (dy >= 0) and ay or -ay
	else
		return (dz >= 0) and az or -az
	end
end

local function quantizeOrthoRotation(cf: CFrame): CFrame
	local pos = cf.Position
	local right = _snapAxis(cf.RightVector)
	local up = _snapAxis(cf.UpVector)

	-- Ensure orthonormal + right-handed
	local look = right:Cross(up)
	if look.Magnitude < 0.5 then
		-- if right/up ended up parallel, fall back to LookVector snap
		local look2 = _snapAxis(cf.LookVector)
		up = look2:Cross(right)
		look = right:Cross(up)
	end
	return CFrame.fromMatrix(pos, right, up)
end

local function applyVisuals(part: BasePart, visual)
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

local function isInsidePlot(targetCf: CFrame, boundary: BasePart): boolean
	if not boundary or not targetCf then return false end

	local worldPos = targetCf.Position
	local localCf = boundary.CFrame:Inverse() * CFrame.new(worldPos)
	local localPos = localCf.Position
	local halfSize = boundary.Size * 0.5

	-- Only care about X/Z (top-down), ignore Y completely
	return (math.abs(localPos.X) <= halfSize.X + 0.01) and (math.abs(localPos.Z) <= halfSize.Z + 0.01)
end

PlaceBlockEvent.OnServerEvent:Connect(function(plr, blockId, cf: CFrame, sourceInstance: Instance?, visualSpec, rotationY)
	local plotModel = PlotManager.GetPlot(plr)
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
	--if cf.Position.Y < minY then
	--	warn(("[Placement] %s attempted to place below floor; blocked."):format(plr.Name))
	--	return
	--end

	if boundary and boundary:IsA("BasePart") and not isInsidePlot(cf, boundary) then
		Notify:FireClient(plr, { text = "Place blocks inside your plot.", duration = 2.0 })
		return
	end

	-- Resolve a spawnable template
	local tpl: Instance? = nil
	local templateNameForSave: string? = nil

	if sourceInstance then
		local isSpawnable = sourceInstance:IsA("BasePart") or (sourceInstance:IsA("Model") and sourceInstance.PrimaryPart)
		local isTemplate = sourceInstance:IsDescendantOf(BlockTemplates)
		local isPaletteSpawnable = BlockPalette and sourceInstance:IsDescendantOf(BlockPalette) and isSpawnable
		if isSpawnable and (isTemplate or isPaletteSpawnable) then
			tpl = sourceInstance
			if isTemplate then
				templateNameForSave = sourceInstance.Name
			end
		end
	end

	if not tpl and visualSpec and visualSpec.TemplateName then
		tpl = resolveTemplateByName(visualSpec.TemplateName)
		templateNameForSave = typeof(visualSpec.TemplateName) == "string" and visualSpec.TemplateName or nil
	end

	if not tpl then
		tpl = resolveTemplateByName("Block_4x4x4")
		templateNameForSave = "Block_4x4x4"
	end

	if not tpl then
		warn(("[Placement] %s attempted to place unknown template; blocked."):format(plr.Name))
		return
	end

	local part = spawnFromTemplate(tpl)
	part.Anchored = true
	part.CanCollide = true
	part.Name = "Block"

	-- Stamp the SHAPE template name so reloads don't guess.
	if templateNameForSave then
		part:SetAttribute("TemplateName", templateNameForSave)
	end

	-- Apply visuals from client (Color/Material/Texture/etc.)
	applyVisuals(part, visualSpec)

	-- Apply the client rotation first (including flips/wedges), then we will snap position only.
	local yaw = cleanYawDegrees(rotationY)
	part.CFrame = cf * CFrame.Angles(0, math.rad(yaw), 0)

	-- Ensure BuildStateService is bound (PlotManager.AssignPlot already binds, but keep this safe.)
	local session = BuildStateService:GetSession(plr)
	if not session then
		BuildStateService:BindPlot(plr, plotModel)
		session = BuildStateService:GetSession(plr)
	end
	if not (session and session.origin) then
		warn("[Placement] Missing BuildStateService session/origin; blocked.")
		return
	end

	-- Compute final cell ONCE (do NOT recompute after rounding/snapping).
	local finalCell = BuildStateService:WorldToCell(plr, part.Position, GridUtil.BLOCK_SIZE)

	-- Deterministic snapped position from Origin + cell center
	local originPos = session.origin.Position
	local bs = GridUtil.BLOCK_SIZE
	local snappedPos = Vector3.new(
		originPos.X + (finalCell[1] + 0.5) * bs,
		originPos.Y + (finalCell[2] + 0.5) * bs,
		originPos.Z + (finalCell[3] + 0.5) * bs
	)
	--print("ORIGIN USED:", session.origin:GetFullName(), session.origin.Position.Y)
	--print("PART SIZE Y:", part.Size.Y, "PART POS Y BEFORE SNAP:", part.Position.Y)
	--print("FINAL CELL Y:", finalCell[2])

	-- Optional: round to 0.1 studs (tenths). Safe because centers are 2 studs from grid lines.
	snappedPos = roundVecTenths(snappedPos)

	-- Preserve full rotation basis (including flips) while snapping position
	local rotOnly = part.CFrame - part.CFrame.Position
	part.CFrame = CFrame.new(snappedPos) * rotOnly

	if USE_ORTHO_ROTATION_QUANTIZE then
		part.CFrame = quantizeOrthoRotation(part.CFrame)
	end
	part.Anchored = true 
	CollectionService:AddTag(part, "PlacedBlock")

	part.Parent = blocksFolder

	-- Save record using the SAME finalCell used for snapping (prevents drift).
	local record = BuildStateService:CreateRecord(plr, blockId, part.CFrame, finalCell, part)
	BuildStateService:AddPlacedPart(plr, record, part)
end)
