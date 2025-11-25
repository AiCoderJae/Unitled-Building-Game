-- StarterPlayerScripts/RemovalController.client.lua
-- Server-side validation + destruction for block removal.
-- Pairs with:
--   • HotbarController_withRemoval.client.lua (X-slot / "removal mode")
--   • RemoteEvent "RemoveBlock" in ReplicatedStorage.Remotes
--
-- Behaviour:
--   • Client, when in removal mode, sends the BasePart under the player's mouse.
--   • Server checks:
--       - The instance is a BasePart
--       - It is tagged "PlacedBlock" (from PlacementService)
--       - It lives inside the calling player's own plot's PlayerPlacedBlocks folder
--   • If all checks pass, the part is destroyed.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local removeBlockRE = Remotes:WaitForChild("RemoveBlock")

local PlotManager = require(ServerScriptService:WaitForChild("Server"):WaitForChild("PlotManager"))

local lastRemovalRequest: {[Player]: number} = {}
local REMOVAL_COOLDOWN = 0.1

local function getPlayerBlocksFolder(plr: Player): Folder?
	local plotModel = PlotManager.GetPlayerPlot(plr)
	if not plotModel then
		return nil
	end

	local blocksFolder = plotModel:FindFirstChild("PlayerPlacedBlocks")
	return blocksFolder :: Folder?
end

local function isBlockOwnedByPlayer(part: BasePart, plr: Player): boolean
	local blocksFolder = getPlayerBlocksFolder(plr)
	if not blocksFolder then
		return false
	end

	if not part:IsDescendantOf(blocksFolder) then
		return false
	end

	-- Optional extra check: rely on the PlacedBlock tag from PlacementService
	if not CollectionService:HasTag(part, "PlacedBlock") then
		return false
	end

	return true
end

removeBlockRE.OnServerEvent:Connect(function(plr, target: Instance)
        local now = os.clock()
        local last = lastRemovalRequest[plr]
        if last and (now - last) < REMOVAL_COOLDOWN then
                return
        end
        lastRemovalRequest[plr] = now

        if typeof(target) ~= "Instance" then
                return
        end

	if not target:IsA("BasePart") then
		return
	end

	if not isBlockOwnedByPlayer(target, plr) then
		-- Either not in their plot folder or missing tag; ignore quietly
		return
	end

	target:Destroy()
end)
