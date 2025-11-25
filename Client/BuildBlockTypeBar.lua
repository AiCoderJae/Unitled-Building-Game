-- BuildBlockTypeBar_noCamera_v1_4.client.lua
-- Variant: does NOT create a Camera. Uses any pre-existing camera placed in the TypeCell template.
-- Cloned shape adopts the template's original orientation/position (pivot) inside the ViewportFrame.
-- If you truly have no camera in the ViewportFrame, Roblox may not render the model;
-- but this honors your request: we won't create or modify a camera at all.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local paletteGui = playerGui:WaitForChild("PaletteGui")      -- ScreenGui
local paletteFrame = paletteGui:WaitForChild("Palette")  

local blockTypeFrame = paletteFrame:WaitForChild("BlockType") -- ScrollingFrame
local typeCellTemplate = blockTypeFrame:WaitForChild("TypeCell")
typeCellTemplate.Visible = false

local assets = ReplicatedStorage:WaitForChild("BlockAssets")
local blockTemplates = assets:WaitForChild("BlockTemplates")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local setBlockTypeBE = remotes:WaitForChild("SetBlockType")

-- Clears previous cloned content but preserves UI children (TextButton etc.) and any pre-placed Camera
local function clearViewportFrame(vp: ViewportFrame)
	for _, c in ipairs(vp:GetChildren()) do
		if c:IsA("BasePart") or c:IsA("Model") or c:IsA("WorldModel") then
			c:Destroy()
		end
	end
end
local function getChildrenSortedByName(parent)
	local list = parent:GetChildren()
	table.sort(list, function(a, b)
		return a.Name < b.Name
	end)
	return list
end

local function shouldPopulateGui(tpl: Instance)
	-- Only show if PopulateGui == true in attributes
	local flag = tpl:GetAttribute("PopulateGui")
	return flag == true
end

-- Inserts the template clone into a WorldModel for better isolation (no physics), adopts original pivot
local function insertCloneWithOriginalPose(vp: ViewportFrame, tpl: Instance)
	clearViewportFrame(vp)

	-- Keep any existing Camera and UI; we won't create a new one.
	-- Use a WorldModel container so we don't pollute the viewport with extra parts.
	local world = Instance.new("WorldModel")
	world.Name = "PreviewWorld"
	world.Parent = vp

	local clone = tpl:Clone()
	clone.Parent = world

	-- Adopt the template's pose: use GetPivot when possible
	if clone:IsA("Model") then
		local pivot = tpl:IsA("Model") and tpl:GetPivot() or CFrame.new()
		clone:PivotTo(pivot)
	elseif clone:IsA("BasePart") then
		local cframe = tpl:IsA("BasePart") and tpl.CFrame or CFrame.new()
		clone.CFrame = cframe
	end

	-- Basic viewport polish (optional)
	vp.BackgroundTransparency = 1
	vp.LightColor = Color3.new(1, 1, 1)
	vp.LightDirection = Vector3.new(-1, -1, -0.4)
	vp.Ambient = Color3.fromRGB(180, 180, 180)
end

local function makeCellForTemplate(tpl: Instance)
	if not (tpl:IsA("BasePart") or tpl:IsA("Model")) then return end

	local cell = typeCellTemplate:Clone()
	cell.Name = "TypeCell_" .. tpl.Name
	cell.Visible = true
	cell.Parent = blockTypeFrame

	-- Insert the clone using the template's original pose; do NOT create a camera
	insertCloneWithOriginalPose(cell, tpl)

	-- Button hook
	local btn = cell:FindFirstChild("BlockTypeButton")
	if btn and btn:IsA("TextButton") then
		btn.Text = ""
		btn.Name = "BlockTypeButton_"..tpl.Name
		btn.Visible = true
		btn.AutoButtonColor = true
		btn.MouseButton1Click:Connect(function()
			local canon = blockTemplates:FindFirstChild(tpl.Name)
			if canon then setBlockTypeBE:Fire(tpl.Name, canon) end
		end)
	end

	-- Also allow clicking anywhere in the cell
	cell.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			local canon = blockTemplates:FindFirstChild(tpl.Name)
			if canon then setBlockTypeBE:Fire(tpl.Name, canon) end
		end
	end)
end

-- Build and keep updated
for _, child in ipairs(getChildrenSortedByName(blockTemplates)) do
	if shouldPopulateGui(child) then
		makeCellForTemplate(child)
	end
end

blockTemplates.ChildAdded:Connect(function(inst)
	if shouldPopulateGui(inst) then
		makeCellForTemplate(inst)
	end
end)

