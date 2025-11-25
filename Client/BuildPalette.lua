-- BuildPalette_TabsAndCache_v1_9.client.lua
-- v1_9: Add Special-block support (clone SourceInstance directly) + type cleanup.
--  • Reads Special (bool Attribute) on items under BlockPalette category folders.
--  • If Special == true, builderSpec holds SourceInstance and palette/placement
--    will clone that instance directly instead of using a BlockTemplate + Visual.
--  • Non-special blocks keep the existing behavior (template + visual overrides).
--  • Also keeps MaterialVariant support + PaletteGui rename + AddToHotbar integration.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

-- ScreenGui
local currentPaletteBlockId = nil

local paletteGui = playerGui:WaitForChild("PaletteGui")

-- Main Frame inside PaletteGui
local buildGui = paletteGui:WaitForChild("Palette")

-- These are now children of the Palette frame
local blocksFrame = buildGui:WaitForChild("Blocks")
local tabsFrame = buildGui:WaitForChild("Tabs")
local tabButtonTemplate = tabsFrame:WaitForChild("TabButton")
local blockCellTemplate = blocksFrame:WaitForChild("BlockCell")
local statusLabel = buildGui:FindFirstChild("BuildStatus")

blockCellTemplate.Visible = false
tabButtonTemplate.Visible = false

local assets = ReplicatedStorage:WaitForChild("BlockAssets")
local paletteRoot = assets:WaitForChild("BlockPalette")
local templatesRoot = assets:WaitForChild("BlockTemplates")
local defaultTemplate = templatesRoot:WaitForChild("Block_4x4x4")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local setBlockIdBE = remotes:WaitForChild("SetBlockId")
local setBlockTypeBE = remotes:WaitForChild("SetBlockType")
local addBlockToHotbarBE = remotes:WaitForChild("AddBlockToHotbar") 

local clearHotbarSelectionBE = remotes:WaitForChild("ClearHotbarSelection")
local clearPaletteSelectionBE = remotes:WaitForChild("ClearPaletteSelection")
--//// Types ////--

type VisualSpec = {
	Color: Color3?,
	Material: Enum.Material?,
	MaterialVariant: string?,
	TextureId: string?,
	StudsPerTileU: number?,
	StudsPerTileV: number?,
}

type BuilderSpec = {
	BlockId: string,
	Category: string,
	Visual: VisualSpec?,
	Special: boolean?,
	SourceInstance: Instance?,
}

type CategoryCacheEntry = {
	specs: {BuilderSpec},
	cells: {Instance},
}

local currentCategory: string? = nil

local function getChildrenSortedByName(parent: Instance)
	local children = parent:GetChildren()
	table.sort(children, function(a, b)
		return a.Name < b.Name
	end)
	return children
end

-- Cache holds builder specs (not finished cells)
local cache: {[string]: CategoryCacheEntry} = {}

local selectedTemplateName = defaultTemplate.Name
local function status(t: string)
	if statusLabel and statusLabel:IsA("TextLabel") then
		statusLabel.Text = t
	end
end

local function materialFrom(anyValue: any): Enum.Material
	if typeof(anyValue) == "EnumItem" then
		return anyValue :: Enum.Material
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

local function clearViewport(vp: ViewportFrame)
        for _, c in ipairs(vp:GetChildren()) do
                if c:GetAttribute("PalettePreview") then
                        c:Destroy()
                end
        end
end

local function applyVisualToBasePart(part: BasePart, visual: VisualSpec?)
	if not part or not visual then
		return
	end
	if visual.Color then
		part.Color = visual.Color
	end
	if visual.Material then
		part.Material = materialFrom(visual.Material)
	end
	-- Apply MaterialVariant AFTER Material so Roblox doesn't reject due to mismatch.
	if visual.MaterialVariant and type(visual.MaterialVariant) == "string" then
		local ok = pcall(function()
			part.MaterialVariant = visual.MaterialVariant
		end)
		if not ok then
			-- ignore silently if variant isn't present in MaterialService
		end
	end
	if visual.TextureId and visual.TextureId ~= "" then
		for _, face in ipairs(Enum.NormalId:GetEnumItems()) do
			local tx = Instance.new("Texture")
			tx.Texture = visual.TextureId
			tx.Face = face
			tx.StudsPerTileU = visual.StudsPerTileU or 4
			tx.StudsPerTileV = visual.StudsPerTileV or 4
			tx.Parent = part
		end
	end
end

local function buildPreviewInstance(template: Instance, visual: VisualSpec?): Instance
	local src = template
	local clone: BasePart?

	if src:IsA("Model") then
		local pp = src.PrimaryPart or src:FindFirstChildWhichIsA("BasePart", true)
		if pp then
			clone = pp:Clone()
		end
	elseif src:IsA("BasePart") then
		clone = src:Clone()
	end
	clone = clone or defaultTemplate:Clone()

	applyVisualToBasePart(clone, visual)
	return clone
end

local function renderCell(cell: Frame, builderSpec: BuilderSpec)
	local vp = cell:FindFirstChildOfClass("ViewportFrame")
        if not vp then
                vp = Instance.new("ViewportFrame")
                vp.Size = UDim2.fromScale(1, 1)
                vp.Parent = cell
        end
        clearViewport(vp)

        local cam = Instance.new("Camera")
        cam.FieldOfView = 40
        cam:SetAttribute("PalettePreview", true)
        cam.Parent = vp
        vp.CurrentCamera = cam
        vp.BackgroundTransparency = 1

	-- For Special blocks, preview the actual SourceInstance without overriding visuals.
	local templateToUse: Instance
	local previewVisual: VisualSpec?

	if builderSpec.Special and builderSpec.SourceInstance then
		templateToUse = builderSpec.SourceInstance
		previewVisual = nil -- keep its own look
	else
		templateToUse = templatesRoot:FindFirstChild(selectedTemplateName) or defaultTemplate
		previewVisual = builderSpec.Visual
		if not templateToUse then
			templateToUse = defaultTemplate
		end
	end

        local preview = buildPreviewInstance(templateToUse, previewVisual)
        preview.Parent = vp

        preview:SetAttribute("PalettePreview", true)

	local p: BasePart?
	if preview:IsA("BasePart") then
		p = preview
	else
		p = preview:FindFirstChildWhichIsA("BasePart", true)
	end

        if p then
            p.CFrame = CFrame.new(0, 1, 0)
            cam.CFrame = CFrame.new(Vector3.new(8, 8, 8), Vector3.new())
        end
end

local function constructCell(blockId: string, builderSpec: BuilderSpec): Frame
	local cell = blockCellTemplate:Clone()
	cell.Name = "BlockCell_" .. blockId
	cell.Visible = true

	-- Support either NameLabel (new) or Label (old) for text
	-- local label = cell:FindFirstChild("NameLabel") or cell:FindFirstChild("Label")
	-- if label and label:IsA("TextLabel") then
	--     label.Text = blockId
	-- end

        local function getPlacementPayload()
                -- Decide how this block should be spawned when selected.
                if builderSpec.Special and builderSpec.SourceInstance then
                        if not builderSpec.SourceInstance:IsDescendantOf(paletteRoot) then
                                warn(("Palette source for %s is missing; cannot select"):format(blockId))
                                return nil
                        end
                        -- Special blocks: directly clone the source instance, no visual overrides.
                        return {
                                Category = builderSpec.Category,
                                Visual = nil,
                                TemplateName = nil,
				SourceInstance = builderSpec.SourceInstance,
				Special = true,
			}
                else
                        -- Normal blocks: use a template from BlockTemplates plus a Visual spec.
                        local templateToUse = templatesRoot:FindFirstChild(selectedTemplateName) or defaultTemplate
                        local templateName = templateToUse and templateToUse.Name or defaultTemplate.Name
                        return {
                                Category = builderSpec.Category,
                                Visual = builderSpec.Visual,
                                TemplateName = templateName,
                                SourceInstance = templateToUse,
                                Special = false,
                        }
                end
        end

	local hit = cell:FindFirstChild("Hitbox")
	hit = (hit and hit:IsA("ImageButton")) and hit or nil
	if hit then
		hit.MouseButton1Click:Connect(function()
			-- 🔹 Palette is now "the boss" → tell hotbar to clear selection
                        if clearHotbarSelectionBE then
                                clearHotbarSelectionBE:Fire()
                        end

                        if currentPaletteBlockId == blockId then
                                -- toggle off
                                currentPaletteBlockId = nil
                                setBlockIdBE:Fire(nil, nil)
                        else
                                -- toggle on
                                currentPaletteBlockId = blockId
                                local payload = getPlacementPayload()
                                if payload then
                                        setBlockIdBE:Fire(blockId, payload)
                                end
                        end
                end)
        end

	-- Hook AddToHotbarButton if present
	local addBtn = cell:FindFirstChild("AddToHotbarButton")
        if addBtn and addBtn:IsA("TextButton") then
                addBtn.MouseButton1Click:Connect(function()
                        if addBlockToHotbarBE then
                                local payload = getPlacementPayload()
                                if payload then
                                        addBlockToHotbarBE:Fire(blockId, payload)
                                end
                        end
                end)
        end

	renderCell(cell, builderSpec)
	return cell
end

local function captureVisualFromItem(item: Instance): VisualSpec
	if item:IsA("Folder") then
		local attrs: VisualSpec = {
			Color = item:GetAttribute("Color"),
			Material = item:GetAttribute("Material") :: Enum.Material?,
			MaterialVariant = item:GetAttribute("MaterialVariant"),
			TextureId = item:GetAttribute("TextureId"),
			StudsPerTileU = item:GetAttribute("StudsPerTileU"),
			StudsPerTileV = item:GetAttribute("StudsPerTileV"),
		}
		local cv = item:FindFirstChild("ColorValue")
		if cv and cv:IsA("Color3Value") then
			attrs.Color = attrs.Color or cv.Value
		end
		local mv = item:FindFirstChild("MaterialValue")
		if mv and mv:IsA("StringValue") then
			attrs.Material = attrs.Material or (mv.Value :: any)
		end
		local mvv = item:FindFirstChild("MaterialVariantValue")
		if mvv and mvv:IsA("StringValue") then
			attrs.MaterialVariant = attrs.MaterialVariant or mvv.Value
		end
		local tv = item:FindFirstChild("TextureId")
		if tv and tv:IsA("StringValue") then
			attrs.TextureId = attrs.TextureId or tv.Value
		end
		return attrs
	end

	local part = item:IsA("BasePart") and item or item:FindFirstChildWhichIsA("BasePart", true)
	if part then
		local vis: VisualSpec = {
			Color = part.Color,
			Material = part.Material,
		}
		-- Pull MaterialVariant from the sample part as well
		local ok, variant = pcall(function()
			-- MaterialVariant is a string on parts that support it
			return (part :: any).MaterialVariant
		end)
		if ok and type(variant) == "string" and variant ~= "" then
			vis.MaterialVariant = variant
		end
		return vis
	end

	return {}
end

local function buildCategorySpecs(categoryFolder: Folder): {BuilderSpec}
	local list: {BuilderSpec} = {}
	-- Get children sorted by Name so palette is consistent
	local children = getChildrenSortedByName(categoryFolder)
	for _, item in ipairs(children) do
		if item:IsA("Color3Value") then
			table.insert(list, {
				BlockId = item.Name,
				Category = categoryFolder.Name,
				Visual = { Color = item.Value },
				Special = false,
				SourceInstance = nil,
			})
		elseif item:IsA("Folder") or item:IsA("Model") or item:IsA("BasePart") then
			local isSpecial = item:GetAttribute("Special") == true
			table.insert(list, {
				BlockId = item.Name,
				Category = categoryFolder.Name,
				Visual = captureVisualFromItem(item),
				Special = isSpecial,
				SourceInstance = isSpecial and item or nil,
			})
		end
	end
	return list
end

local function forceDestroyVisibleCells()
	for _, child in ipairs(blocksFrame:GetChildren()) do
		if child:IsA("GuiObject") and child ~= blockCellTemplate then
			child:Destroy()
		end
	end
end

local function showCategory(name: string)
	currentCategory = name
	status("Loading " .. name .. "...")
	local entry = cache[name]
	if not entry then
		local folder = paletteRoot:FindFirstChild(name)
		if not folder or not folder:IsA("Folder") then
			warn("Missing category: " .. name)
			return
		end
		local specs = buildCategorySpecs(folder)
		entry = { specs = specs, cells = {} }
		cache[name] = entry
	end

	forceDestroyVisibleCells()
	entry.cells = {}
	for _, spec in ipairs(entry.specs) do
		local cell = constructCell(spec.BlockId, spec)
		cell.Parent = blocksFrame
		table.insert(entry.cells, cell)
	end
	status("Showing " .. name .. " (" .. selectedTemplateName .. ")")
end

local function buildTabs()
	for _, c in ipairs(tabsFrame:GetChildren()) do
		if c:IsA("TextButton") and c ~= tabButtonTemplate then
			c:Destroy()
		end
	end

	local first: string? = nil

	-- Sort category folders by Name for consistent tab order
	local folders = getChildrenSortedByName(paletteRoot)

	for _, folder in ipairs(folders) do
		if folder:IsA("Folder") then
			local tab = tabButtonTemplate:Clone()
			tab.Visible = true
			tab.Name = "Tab_" .. folder.Name
			tab.Text = folder.Name
			tab.Parent = tabsFrame

			tab.MouseButton1Click:Connect(function()
				showCategory(folder.Name)
			end)

			first = first or folder.Name
		end
	end

	if first then
		showCategory(first)
	end
end

setBlockTypeBE.Event:Connect(function(tplName: string, _tplInst: Instance)
	if typeof(tplName) ~= "string" then
		return
	end
	if not templatesRoot:FindFirstChild(tplName) then
		return
	end
	selectedTemplateName = tplName
	if currentCategory then
		showCategory(currentCategory)
	end
end)

local function clearPaletteSelection()
	if currentPaletteBlockId ~= nil then
		currentPaletteBlockId = nil
		-- if we have a helper that re-highlights cells, call it here
		-- e.g. refreshSelectedCell() if we wrote one
	end
end

clearPaletteSelectionBE.Event:Connect(function()
	clearPaletteSelection()
end)

buildTabs()
paletteRoot.ChildAdded:Connect(buildTabs)
paletteRoot.ChildRemoved:Connect(buildTabs)
