-- StarterPlayerScripts/Client/HotbarController.client.lua
-- Handles hotbar slots, interaction with PaletteGui, and selection for PlacementController.
-- Now also wires a dedicated "remover" slot (X key) that lets players delete their own blocks.
--
-- Expects:
--   • PlayerGui.HotbarGui.Bar as the container for slots
--   • A Frame template named "HotbarSlotTemplate" either under:
--       - ReplicatedStorage.ReplicatingAssets, or
--       - HotbarGui.Bar
--   • A Frame template named "HotbarRemoverSlot" under:
--       - ReplicatedStorage.ReplicatingAssets
--     with children:
--       - Hitbox (ImageButton)
--       - Icon (ImageLabel)
--       - KeyLabel (TextLabel; will be set to "X" here)
--   • Each normal slot frame has:
--       - ViewportFrame
--       - Hitbox (GuiButton)
--       - RemoveFromHotbarButton (GuiButton)
--       - KeyLabel (TextLabel)
--   • ReplicatedStorage.Remotes:
--       - BindableEvent "AddBlockToHotbar"
--       - BindableEvent "SetBlockId"
--       - RemoteEvent  "RemoveBlock"      (new: for server-side RemovalService)
--
-- Special block support:
--   • If spec.Special == true and spec.SourceInstance is provided, the hotbar
--     preview and selection will use that instance directly (no BlockTemplate
--     or Visual overrides).
--   • Normal blocks keep the existing behavior: template from BlockTemplates
--     plus Visual overrides.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local mouse = player:GetMouse()

-- 🔥 Hotbar stays the same visually, with an extra remover slot on the far left
local hotbarGui = playerGui:WaitForChild("HotbarGui")
local bar = hotbarGui:WaitForChild("Bar")

-- Optional (palette reference, not required here but correct with new structure)
local paletteGui = playerGui:WaitForChild("PaletteGui")   -- ScreenGui
local paletteFrame = paletteGui:WaitForChild("Palette")   -- Frame

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local addBlockToHotbarBE = remotes:WaitForChild("AddBlockToHotbar")
local setBlockIdBE = remotes:WaitForChild("SetBlockId")
local removeBlockRE = remotes:WaitForChild("RemoveBlock")  -- RemoteEvent used by RemovalService

local assets = ReplicatedStorage:WaitForChild("BlockAssets")
local templatesRoot = assets:WaitForChild("BlockTemplates")
local defaultTemplate = templatesRoot:WaitForChild("Block_4x4x4")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local clearHotbarSelectionBE = remotes:WaitForChild("ClearHotbarSelection")
local clearPaletteSelectionBE = remotes:WaitForChild("ClearPaletteSelection")
local MAX_SLOTS = 8

-- Resolve the normal slot template (prefer central ReplicatingAssets but fall back to local one)
local replicatingAssets = ReplicatedStorage:FindFirstChild("ReplicatingAssets")
local slotTemplate: Frame? = nil
local removerTemplate: Frame? = nil

if replicatingAssets then
	local candidate = replicatingAssets:FindFirstChild("HotbarSlotTemplate")
	if candidate and candidate:IsA("Frame") then
		slotTemplate = candidate
	end

	local remCandidate = replicatingAssets:FindFirstChild("HotbarRemoverSlot")
	if remCandidate and remCandidate:IsA("Frame") then
		removerTemplate = remCandidate
	end
end

if not slotTemplate then
	local candidate = bar:FindFirstChild("HotbarSlotTemplate")
	if candidate and candidate:IsA("Frame") then
		slotTemplate = candidate
	end
end

assert(slotTemplate, "HotbarSlotTemplate not found. Place it under ReplicatedStorage/ReplicatingAssets or HotbarGui.Bar.")
assert(removerTemplate, "HotbarRemoverSlot not found. Place it under ReplicatedStorage/ReplicatingAssets.")

slotTemplate.Visible = false
removerTemplate.Visible = false

--//// Types ////--

type VisualSpec = {
	Color: Color3?,
	Material: any?,
	MaterialVariant: string?,
	TextureId: string?,
	StudsPerTileU: number?,
	StudsPerTileV: number?,
}

type SlotSpec = {
	BlockId: string,
	Category: string?,
	Visual: VisualSpec?,
	TemplateName: string?,
	SourceInstance: Instance?,
	Special: boolean?,
}

local slots: {SlotSpec?} = table.create(MAX_SLOTS, nil)
local slotFrames: {Frame?} = table.create(MAX_SLOTS, nil)
local selectedIndex: number? = nil

-- Removal mode state (for the X-slot)
local removalActive: boolean = false
local removerSlot: Frame? = nil
-- highlight stuff
local removalHighlight: SelectionBox? = nil
local highlightedPart: BasePart? = nil

local function materialFrom(anyValue: any)
	if typeof(anyValue) == "EnumItem" then
		return anyValue
	end
	if typeof(anyValue) == "string" then
		local ok, res = pcall(function()
			return Enum.Material[anyValue]
		end)
		if ok then
			return res
		end
	end
	return Enum.Material.SmoothPlastic
end

local function applyVisualToBasePart(part: BasePart, visual: VisualSpec?)
	if not part or not visual then
		return
	end

	if visual.Color then
		part.Color = visual.Color
	end

	if visual.Material then
		local ok, mat = pcall(function()
			if typeof(visual.Material) == "EnumItem" then
				return visual.Material
			else
				return Enum.Material[visual.Material]
			end
		end)
		if ok and mat then
			part.Material = mat
		end
	end

	-- MaterialVariant after Material
	if visual.MaterialVariant and type(visual.MaterialVariant) == "string" then
		pcall(function()
			(part :: any).MaterialVariant = visual.MaterialVariant
		end)
	end

        -- Clear any textures we previously added for previews
        for _, child in ipairs(part:GetChildren()) do
                if child:IsA("Texture") and child:GetAttribute("HotbarPreviewTexture") then
                        child:Destroy()
                end
        end

	if visual.TextureId and visual.TextureId ~= "" then
		for _, face in ipairs(Enum.NormalId:GetEnumItems()) do
                        local tx = Instance.new("Texture")
                        tx.Texture = visual.TextureId
                        tx.Face = face
                        tx.StudsPerTileU = visual.StudsPerTileU or 4
                        tx.StudsPerTileV = visual.StudsPerTileV or 4
                        tx:SetAttribute("HotbarPreviewTexture", true)
                        tx.Parent = part
                end
        end
end

local function clearViewport(vp: ViewportFrame)
	for _, c in ipairs(vp:GetChildren()) do
		if c:IsA("Camera") or c:IsA("WorldModel") or c:IsA("Model") or c:IsA("BasePart") then
			c:Destroy()
		end
	end
end

local function getOrCreateViewport(frame: Frame): ViewportFrame?
	local vp = frame:FindFirstChildOfClass("ViewportFrame")
	if not vp then
		vp = Instance.new("ViewportFrame")
		vp.Size = UDim2.fromScale(1, 1)
		vp.BackgroundTransparency = 1
		vp.Parent = frame
	end
	return vp
end

local function renderSlot(index: number)
	local frame = slotFrames[index]
	if not frame then
		return
	end

	local vp = getOrCreateViewport(frame)
	if not vp then
		return
	end

	clearViewport(vp)

	local cam = Instance.new("Camera")
	cam.FieldOfView = 40
	cam.Parent = vp
	vp.CurrentCamera = cam

	local data = slots[index]
	if not data then
		return
	end

	-- Decide what instance to preview
	local template: Instance = defaultTemplate
	local visualForPreview: VisualSpec? = data.Visual

	if data.Special and data.SourceInstance then
		-- Special block: use the original instance, no visual overrides
		template = data.SourceInstance
		visualForPreview = nil
	else
		-- Normal block: template + visual
		if data.TemplateName and templatesRoot:FindFirstChild(data.TemplateName) then
			template = templatesRoot:FindFirstChild(data.TemplateName)
		end
	end

	local clone: BasePart? = nil

	if template:IsA("Model") then
		local pp = template.PrimaryPart or template:FindFirstChildWhichIsA("BasePart", true)
		if pp then
			clone = pp:Clone()
		end
	elseif template:IsA("BasePart") then
		clone = template:Clone()
	else
		local bp = template:FindFirstChildWhichIsA("BasePart", true)
		if bp then
			clone = bp:Clone()
		end
	end

	clone = clone or defaultTemplate:Clone()

	applyVisualToBasePart(clone, visualForPreview)

	local worldModel = Instance.new("WorldModel")
	worldModel.Name = "WorldModel"
	worldModel.Parent = vp

	clone.CFrame = CFrame.new(0, .5, 0)
	clone.Parent = worldModel

	cam.CFrame = CFrame.new(Vector3.new(8, 8, 8), Vector3.new(0, 0, 0))
end

local function updateSelectionHighlight()
	for i, frame in ipairs(slotFrames) do
		if frame then
			if selectedIndex == i then
				frame.BorderSizePixel = 2
				frame.BorderColor3 = Color3.new(1, 1, 1)
			else
				frame.BorderSizePixel = 0
			end
		end
	end

	-- Remover visual
	if removerSlot then
		if removalActive then
			removerSlot.BorderSizePixel = 2
			removerSlot.BorderColor3 = Color3.new(1, 1, 1)
		else
			removerSlot.BorderSizePixel = 0
		end
	end
end

clearHotbarSelectionBE.Event:Connect(function()
	if selectedIndex ~= nil then
		selectedIndex = nil
		updateSelectionHighlight()
	end
end)
local function setHighlightedPart(part: BasePart?)
	if highlightedPart == part then
		return
	end

	highlightedPart = part

	if part and removalActive then
		if not removalHighlight then
			removalHighlight = Instance.new("SelectionBox")
			removalHighlight.LineThickness = 0.05
			removalHighlight.SurfaceTransparency = 0.8
			removalHighlight.Color3 = Color3.fromRGB(255, 60, 60) -- red-ish
			removalHighlight.SurfaceColor3 = Color3.fromRGB(255, 60, 60) -- red fill 
			removalHighlight.SurfaceTransparency = 0.9    
			removalHighlight.Parent = workspace
		end

		removalHighlight.Adornee = part
		removalHighlight.Visible = true
	else
		if removalHighlight then
			removalHighlight.Visible = false
			removalHighlight.Adornee = nil
		end
	end
end

local function setRemovalMode(active: boolean)
	if removalActive == active then
		return
	end

	removalActive = active
	hotbarGui:SetAttribute("RemovalActive", removalActive)

	if removalActive then
		selectedIndex = nil
		setBlockIdBE:Fire(nil, nil)

		if clearPaletteSelectionBE then
			clearPaletteSelectionBE:Fire()
		end
	end

	updateSelectionHighlight()
end



local function selectSlot(index: number)
	-- if we were in removal mode, exit it
	if removalActive then
		setRemovalMode(false)
	end

	-- toggle behaviour: second click unequips
	if selectedIndex == index then
		selectedIndex = nil
		updateSelectionHighlight()
		setBlockIdBE:Fire(nil, nil)
		return
	end

	selectedIndex = index
	updateSelectionHighlight()

	-- 🔹 Hotbar is now "the boss" → tell palette to clear its selection
	if clearPaletteSelectionBE then
		clearPaletteSelectionBE:Fire()
	end

	-- equip block from this slot
	local data = slots[index]
	if not data then
		setBlockIdBE:Fire(nil, nil)
		return
	end

	setBlockIdBE:Fire(data.BlockId, {
		Category = data.Category,
		Visual = data.Visual,
		TemplateName = data.TemplateName,
		SourceInstance = data.SourceInstance,
		Special = data.Special,
	})
end


local function clearSlot(index: number)
        slots[index] = nil
        if selectedIndex == index then
                selectedIndex = nil
                updateSelectionHighlight()
                setBlockIdBE:Fire(nil, nil)
        end
        renderSlot(index)
end

-- Build remover slot first so it appears on the far left
do
	local slot = removerTemplate:Clone()
	slot.Name = "HotbarRemoverSlot"
	slot.Visible = true
	slot.Parent = bar

	removerSlot = slot

	local keyLabel = slot:FindFirstChild("KeyLabel")
	if keyLabel and keyLabel:IsA("TextLabel") then
		keyLabel.Text = "X"
	end

	local hitbox = slot:FindFirstChild("Hitbox")
	if hitbox and hitbox:IsA("GuiButton") then
		hitbox.MouseButton1Click:Connect(function()
			setRemovalMode(not removalActive)
		end)
	end
end

-- Build the 1..MAX_SLOTS UI (these come after the remover in the Bar's layout)
for i = 1, MAX_SLOTS do
	local slot = slotTemplate:Clone()
	slot.Name = "HotbarSlot_" .. i
	slot.Visible = true
	slot.Parent = bar

	slot:SetAttribute("SlotIndex", i)

	slotFrames[i] = slot

	local keyLabel = slot:FindFirstChild("KeyLabel")
	if keyLabel and keyLabel:IsA("TextLabel") then
		keyLabel.Text = tostring(i)
	end

	local hitbox = slot:FindFirstChild("Hitbox")
	if hitbox and hitbox:IsA("GuiButton") then
		hitbox.MouseButton1Click:Connect(function()
			local idx = slot:GetAttribute("SlotIndex")
			if typeof(idx) == "number" then
				selectSlot(idx)
			end
		end)
	end

	local removeBtn = slot:FindFirstChild("RemoveFromHotbarButton")
	if removeBtn and removeBtn:IsA("GuiButton") then
		removeBtn.MouseButton1Click:Connect(function()
			local idx = slot:GetAttribute("SlotIndex")
			if typeof(idx) == "number" then
				clearSlot(idx)
			end
		end)
	end
end

-- Keyboard input:
--   X key  -> toggle remover mode
--   1..8   -> select slots
UserInputService.InputBegan:Connect(function(input, gp)
	if gp then
		return
	end

	if input.KeyCode == Enum.KeyCode.X then
		setRemovalMode(not removalActive)
		return
	end

	local index: number? = nil
	if input.KeyCode == Enum.KeyCode.One then
		index = 1
	elseif input.KeyCode == Enum.KeyCode.Two then
		index = 2
	elseif input.KeyCode == Enum.KeyCode.Three then
		index = 3
	elseif input.KeyCode == Enum.KeyCode.Four then
		index = 4
	elseif input.KeyCode == Enum.KeyCode.Five then
		index = 5
	elseif input.KeyCode == Enum.KeyCode.Six then
		index = 6
	elseif input.KeyCode == Enum.KeyCode.Seven then
		index = 7
	elseif input.KeyCode == Enum.KeyCode.Eight then
		index = 8
	end

	if index then
		selectSlot(index)
	end
end)

-- Removal click handling: when in removal mode, left-clicking a placed block
-- will request the server to remove it (RemovalService validates ownership).
mouse.Button1Down:Connect(function()
	if not removalActive then
		return
	end

        local target = mouse.Target
        if not (target and target:IsA("BasePart")) then
                return
        end

        if not CollectionService:HasTag(target, "PlacedBlock") then
                return
        end

        -- Fire to server; RemovalService will check tags/ownership and destroy if valid
        removeBlockRE:FireServer(target)
        setHighlightedPart(nil)
end)

--highlight renderstepped loop
RunService.RenderStepped:Connect(function()
	if not removalActive then
		setHighlightedPart(nil)
		return
	end

	local target = mouse.Target
	if target and target:IsA("BasePart") and CollectionService:HasTag(target, "PlacedBlock") then
		setHighlightedPart(target)
	else
		setHighlightedPart(nil)
	end
end)

-- Handle incoming "add to hotbar" requests from the palette
addBlockToHotbarBE.Event:Connect(function(blockId: string, spec: any)
	if typeof(blockId) ~= "string" or typeof(spec) ~= "table" then
		return
	end

	local slotSpec: SlotSpec = {
		BlockId = blockId,
		Category = spec.Category,
		Visual = spec.Visual,
		TemplateName = spec.TemplateName,
		SourceInstance = spec.SourceInstance,
		Special = spec.Special,
	}

	-- Find an empty slot first
	local targetIndex: number? = nil
	for i = 1, MAX_SLOTS do
		if not slots[i] then
			targetIndex = i
			break
		end
	end

	-- If no empty slots, override the currently selected slot or slot 1
	if not targetIndex then
		targetIndex = selectedIndex or 1
	end

	slots[targetIndex] = slotSpec
	renderSlot(targetIndex)
end)
