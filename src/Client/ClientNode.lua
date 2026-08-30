--!strict
local SharedNode = require(script.Parent.SharedNode)
local ClientNode = {}
ClientNode.NIL = SharedNode.NIL
local BroadcastRemote = script.Parent:WaitForChild("BroadcastRemote") :: RemoteEvent
local PendingBroadcasts: { any } = {}
export type ClientNodeExtra = {
	broadcastToServer: () -> (),
}
-- No separate type function needed: NodeType already accepts an Extra
-- type and merges its properties in. This is exactly what Extra was
-- built for, and mirrors how ServerNode should do the same with its
-- own addSync/setSync extra shape.
export type ClientNode<T> = SharedNode.NodeType<T, ClientNodeExtra>
local function decorateClient(node: any)
	-- Sends this node's CURRENT value to the server, for it to consider applying to
	-- server-trusted state - the client-side half of the addSync/allowClientBroadcast system.
	--   GameState.Players[userId].Settings.Update(function(old) old.volume = 50; return old end)
	--   GameState.Players[userId].Settings.broadcastToServer()
	-- This only works if the server called allowClientBroadcast for this exact path and this
	-- player - otherwise the server just discards it with a warning, no error on the client. It
	-- also only works if the server's validateData (if any) accepts the value - if it doesn't,
	-- again, silently discarded server-side. This does NOT immediately update anything on the
	-- server - it queues the send for the next network flush (up to about 1/60th of a second
	-- later), and even then, whether it actually applies depends entirely on the server accepting
	-- it. Write locally first (as above) so your own client's copy updates immediately, then
	-- call this to ask the server to accept the same change.
	node.broadcastToServer = function()
		table.insert(PendingBroadcasts, {
			path = SharedNode.getNodePath(node),
			data = node(),
		})
	end
end
-- Creates the root GameState node on the client. You won't normally call this yourself -
-- Client.lua does it once, automatically, when the module is first required.
function ClientNode.new<T>(key: any, data: T): ClientNode<T>
	local node = SharedNode.new(key, data, decorateClient)
	return (node :: any) :: ClientNode<T>
end
game:GetService("RunService").Heartbeat:Connect(function()
	if #PendingBroadcasts > 0 then
		BroadcastRemote:FireServer(PendingBroadcasts)
		PendingBroadcasts = {}
	end
end)
return ClientNode
