--!strict
local Node = require(script.ClientNode)
local Template = require(script.Template)
local GameState = Node.new("GameState", Template) :: Node.ClientNode<Template.Template>
GameState.NIL = Node.NIL
local SyncRemote = script:WaitForChild("SyncRemote")
SyncRemote.OnClientEvent:Connect(function(batch: { any })
	for _, entry in batch do
		local ok, err = pcall(function()
			local target = GameState
			for _, key in entry.path do
				target = target[key]
			end
			target = target :: any
			target(entry.value)
		end)
		if not ok then
			warn("[GameState] Error applying a synced update, skipping this entry: "..tostring(err))
		end
	end
end)
return GameState
