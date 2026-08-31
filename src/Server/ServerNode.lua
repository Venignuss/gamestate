--!strict
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

if RunService:IsClient() then
	return {} :: any
end

local ClientFolder = script.Parent.Parent.Client

local SyncRemote = ClientFolder:FindFirstChild("SyncRemote") :: RemoteEvent?
if not SyncRemote then
	SyncRemote = Instance.new("RemoteEvent")
	SyncRemote.Name = "SyncRemote"
	SyncRemote.Parent = ClientFolder
end
SyncRemote = SyncRemote :: RemoteEvent
local PendingSync: { [Player]: { any } } = {}

-- The actual per-player sync/broadcast bookkeeping (which includes closures that
-- capture the node itself, e.g. disconnect functions) lives as FIELDS DIRECTLY ON
-- EACH NODE (_syncConnections / _broadcastRegistry), not in an external table keyed
-- by node. Storing such a closure as a VALUE in an external table that's ALSO
-- weak-keyed BY that same node does not actually get collected in Luau, even
-- though it looks like the standard "weak key" idiom - the closure holds its
-- own strong reference back to the node, so the weak key never loses its only
-- reference. Putting the data on the node itself instead makes it a
-- self-contained cycle (node -> node's own field -> closure -> node), which
-- Luau's GC does collect correctly (the same way a node's own metatable,
-- which also closes over the node, is already collectible).
--
-- These two tables exist ONLY so the Heartbeat loop and PlayerRemoving cleanup
-- can enumerate "which nodes currently have a registration" without walking the
-- whole tree - their values are ALWAYS the literal `true` marker, never a
-- closure or anything else that could reference the node back.
local SyncedNodes: { [any]: true } = setmetatable({}, {__mode = "k"}) :: any
local BroadcastableNodes: { [any]: true } = setmetatable({}, {__mode = "k"}) :: any

local BroadcastRemote = ClientFolder:FindFirstChild("BroadcastRemote") :: RemoteEvent?
if not BroadcastRemote then
	BroadcastRemote = Instance.new("RemoteEvent")
	BroadcastRemote.Name = "BroadcastRemote"
	BroadcastRemote.Parent = ClientFolder
end
BroadcastRemote = BroadcastRemote :: RemoteEvent
local PendingBroadcasts: { [Player]: { any } } = {}

-- Frame-level cap on how many broadcast entries a single player can enqueue per
-- Heartbeat. 20 comfortably covers legitimate UI-driven writes (a settings panel,
-- inventory drag-drop, a lever pull) while bounding worst-case per-frame processing
-- cost. Raise it if your game has denser client-write patterns (e.g. real-time
-- drawing/building tools).
local MAX_BROADCASTS_PER_PLAYER_PER_FRAME = 20
local MAX_BROADCAST_PATH_LENGTH = 16
local MAX_BROADCAST_DATA_DEPTH = 16
local MAX_BROADCAST_DATA_NODES = 500 -- total values walked; bounds cost cheaply, exits early
local MAX_BROADCAST_STRING_LENGTH = 2000 -- max length of any single string value in a payload;
	-- MAX_BROADCAST_DATA_NODES counts table entries, not bytes, so without this a single
	-- oversized string leaf would pass the node-count check untouched

-- Token bucket limiting raw BroadcastRemote:FireServer call *frequency*, independent
-- of payload size/shape - MAX_BROADCASTS_PER_PLAYER_PER_FRAME/size checks above don't
-- stop a client from calling FireServer itself extremely rapidly with small/empty
-- payloads, and each call has real server-side dispatch cost regardless of content.
-- Defaults allow short legitimate bursts (a flurry of clicks) while capping sustained
-- spam at 5 calls/sec - tune BROADCAST_BUCKET_CAPACITY (max burst) and
-- BROADCAST_BUCKET_REFILL_PER_SECOND (sustained rate) to your game's actual needs.
local BROADCAST_BUCKET_CAPACITY = 10
local BROADCAST_BUCKET_REFILL_PER_SECOND = 5
local BroadcastBuckets: { [Player]: { tokens: number, lastRefill: number } } = setmetatable({}, {__mode = "k"}) :: any

local function consumeBroadcastToken(player: Player): boolean
	local bucket = BroadcastBuckets[player]
	local now = os.clock()
	if not bucket then
		bucket = { tokens = BROADCAST_BUCKET_CAPACITY, lastRefill = now }
		BroadcastBuckets[player] = bucket
	end
	local elapsed = now - bucket.lastRefill
	if elapsed > 0 then
		bucket.tokens = math.min(BROADCAST_BUCKET_CAPACITY, bucket.tokens + elapsed * BROADCAST_BUCKET_REFILL_PER_SECOND)
		bucket.lastRefill = now
	end
	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end
	return false
end

local SharedNode = require(script.Parent.Parent.Client.SharedNode)
local ServerNode = {}
ServerNode.NIL = SharedNode.NIL

type ServerExtra = {
	addSync: (Player) -> (),
	setSync: ({Player}) -> (),
	removeSync: (Player) -> (),
	allowClientBroadcast: (Player, ((any) -> boolean)?, ((Player) -> {any})?) -> (),
	disallowClientBroadcast: (Player) -> (),
}

export type ServerNode<T> = SharedNode.NodeType<T, ServerExtra>

-- Takes a pre-computed `path` (plain array of keys) rather than `node` itself,
-- so callers building a Changed-callback closure around this don't need to
-- capture `node` - a node's path is fixed for its lifetime (Key/Parent never
-- change), so it's safe to compute once and reuse.
local function queueSync(path: {any}, player: Player, value: any)
	if not PendingSync[player] then
		PendingSync[player] = {}
	end
	table.insert(PendingSync[player], {
		path = path,
		value = value,
	})
end

local function pathStartsWith(path: {any}, prefix: {any}): boolean
	if #path < #prefix then
		return false
	end
	for i, key in prefix do
		if path[i] ~= key then
			return false
		end
	end
	return true
end

local function isWithinDataLimits(data: any, maxDepth: number, maxNodes: number, maxStringLength: number): boolean
	local nodeCount = 0
	local function walk(value: any, depth: number): boolean
		nodeCount += 1
		if nodeCount > maxNodes then
			return false
		end
		if typeof(value) == "string" and #value > maxStringLength then
			return false
		end
		if typeof(value) ~= "table" then
			return true
		end
		if depth > maxDepth then
			return false
		end
		for _, v in value do
			if not walk(v, depth + 1) then
				return false
			end
		end
		return true
	end
	return walk(data, 0)
end

local function reconstructAndValidate(registration: any, message: any): (boolean, any)
	local suffix = {}
	for i = #registration.path + 1, #message.path do
		table.insert(suffix, message.path[i])
	end
	local current = registration.node() -- full current, server-trusted snapshot
	if current == nil and #suffix > 0 then
		current = {}
	end
	if #suffix == 0 then
		current = message.data -- broadcast targeted the registered node itself directly
	else
		local target = current
		for i = 1, #suffix - 1 do
			if target[suffix[i]] == nil then
				target[suffix[i]] = {}
			end
			target = target[suffix[i]]
		end
		target[suffix[#suffix]] = message.data
	end

	if registration.validateData then
		registration = registration :: any
		if not registration.validateData(current) then
			return false, nil
		end
	end
	return true, current
end

local function assertIsPlayer(player: any)
	assert(typeof(player) == "Instance" and player:IsA("Player"), "[GameState] expected a Player instance, got "..typeof(player))
end

-- This is where addSync/setSync/removeSync/allowClientBroadcast actually get implemented:
local function decorateServer(node: any)
	-- Starts replicating this node's value to the given player (or list of players) - every
	-- future change to it gets pushed to their client automatically, plus an immediate initial
	-- push of whatever the value currently is. This is how you get server state onto a client
	-- at all - nothing replicates unless you explicitly addSync it.
	--   GameState.Players[userId].PublicProfile.addSync(player)
	-- Safe to call more than once for the same player - it won't double-subscribe.
	-- No need to clean this up when the player leaves - that happens automatically (see
	-- PlayerRemoving below). You only need removeSync if you want to stop syncing to a player
	-- who's still connected (e.g. they're no longer allowed to see this data).
	node.addSync = function(players: Player | {Player})
		if typeof(players) ~= "table" then
			players = {players}
		end
		if not rawget(node, "_syncConnections") then
			rawset(node, "_syncConnections", {})
		end
		local connections = rawget(node, "_syncConnections")
		local path = SharedNode.getNodePath(node) -- plain array, safe to capture below
		for _, player in players do
			assertIsPlayer(player)
			if connections[player] then
				continue -- already synced, don't double-subscribe
			end
			local disconnect = node.Changed(function(old, new)
				queueSync(path, player, new)
			end)
			queueSync(path, player, node())
			connections[player] = disconnect
			SyncedNodes[node] = true
		end
	end

	-- Stops replicating this node to the given player(s) while they're still connected. If
	-- they're leaving the game, you don't need to call this yourself - PlayerRemoving handles
	-- it automatically.
	node.removeSync = function(players: Player | {Player})
		if typeof(players) ~= "table" then
			players = {players}
		end
		local connections = rawget(node, "_syncConnections")
		for _, player in players do
			assertIsPlayer(player)
			if connections and connections[player] then
				connections[player]()
				connections[player] = nil
			end
		end
		if connections and next(connections) == nil then
			SyncedNodes[node] = nil
		end
	end

	-- Sets the exact list of who this node syncs to, in one call - adds anyone missing and
	-- removes anyone not in the list. Handy when "who should see this" changes as a whole
	-- (e.g. a team/party roster), instead of manually diffing addSync/removeSync calls yourself.
	--   GameState.Parties[partyId].SharedState.setSync(currentPartyMembers)
	node.setSync = function(players: {Player})
		local wanted = {}
		for _, p in players do
			wanted[p] = true
		end
		local connections = rawget(node, "_syncConnections") or {}
		for p in connections do
			if not wanted[p] then
				node.removeSync(p)
			end
		end
		for p in wanted do
			node.addSync(p)
		end
	end

	-- Lets a specific client write to this node from their end, via broadcastToServer() on the
	-- client. This is the ONLY way client-written data can reach server-trusted state - a client
	-- can never just write to GameState directly, they have to be explicitly allowed per node,
	-- per player.
	--   GameState.Players[userId].Settings.allowClientBroadcast(player, function(value)
	--       return typeof(value) == "table" and typeof(value.volume) == "number"
	--   end)
	-- `validateData` gets called with whatever the client sent, and must return true for the
	-- write to actually apply - return false (or nil) to reject it. STRONGLY recommended to
	-- always pass one: without it, this player can write ANYTHING correctly-shaped to this path,
	-- no questions asked (you'll get a warning in the output every time you skip it, as a
	-- reminder). `clientPath` is optional and only needed if you want the client to address this
	-- node by a different path than its real one server-side.
	-- No need to clean this up when the player leaves - handled automatically.
	node.allowClientBroadcast = function(
		player: Player,
		validateData: ((any) -> boolean)?,
		clientPath: {any}?
	)
		assertIsPlayer(player)

		-- A registered broadcast target isn't "idle" even if nothing's been written
		-- to it yet - without this, the node can get auto-detached shortly after
		-- registration (existing idle-phantom cleanup), and once garbage collected,
		-- this entire registration silently vanishes with it.
		SharedNode.clearPhantomChain(node)

		if not validateData then
			local pathParts = {}
			for _, key in SharedNode.getNodePath(node) do
				table.insert(pathParts, tostring(key))
			end
			warn("[GameState] allowClientBroadcast for "..player.Name.." on GameState."..
				table.concat(pathParts, ".")..
				" has no validateData - any correctly-shaped value will be accepted from this "..
				"player as-is. Pass a validateData function unless you intend to fully trust this player's writes.")
		end

		if not rawget(node, "_broadcastRegistry") then
			rawset(node, "_broadcastRegistry", {})
		end
		rawget(node, "_broadcastRegistry")[player] = {
			validateData = validateData,
			clientPath = clientPath,
			path = SharedNode.getNodePath(node),
		}
		BroadcastableNodes[node] = true
	end

	-- Revokes a player's permission to broadcast-write to this node. Same as removeSync - you
	-- only need this for revoking access from someone still connected; leaving players are
	-- cleaned up automatically.
	node.disallowClientBroadcast = function(player: Player)
		assertIsPlayer(player)
		local registry = rawget(node, "_broadcastRegistry")
		if registry then
			registry[player] = nil
			if next(registry) == nil then
				BroadcastableNodes[node] = nil
			end
		end
	end
end

-- Creates the root GameState node on the server. You won't normally call this yourself -
-- Server.lua does it once, automatically, when the module is first required.
function ServerNode.new<T>(key: any, data: T): ServerNode<T>
	local node = SharedNode.new(key, data, decorateServer)
	return (node :: any) :: ServerNode<T>
end

task.spawn(function()
	RunService.Heartbeat:Connect(function()

		-- Syncing

		for player, queue in PendingSync do
			if #queue > 0 then
				SyncRemote:FireClient(player, queue)
				PendingSync[player] = {}
			end
		end

		-- Broadcasting

		for player, queue in PendingBroadcasts do
			for _, message in queue do
				local entryOk, entryErr = pcall(function()
					if typeof(message) ~= "table" or typeof(message.path) ~= "table" then
						warn("[GameState] "..player.Name.." sent a malformed broadcast entry, discarding")
						return
					end

					local bestMatch: {
						node: any,
						validateData: ((any) -> boolean)?,
						path: {any},
					}? = nil
					local bestMatchLength = -1

					-- Note: this is an O(registered nodes) scan per message. Fine as long as
					-- allowClientBroadcast registrations stay modest in number; revisit with an
					-- indexed structure (e.g. trie by path) if this ever needs to scale up.
					for node in BroadcastableNodes do
						local playerRegs = rawget(node, "_broadcastRegistry")
						local reg = playerRegs and playerRegs[player]
						if reg then
							local expectedPath = reg.clientPath or reg.path
							if pathStartsWith(message.path, expectedPath) then
								if #expectedPath == bestMatchLength then
									warn("[GameState] Broadcast path collision for "..player.Name..", ignoring duplicate match")
								elseif #expectedPath > bestMatchLength then
									bestMatch = {
										node = node,
										validateData = reg.validateData,
										path = expectedPath
									}
									bestMatchLength = #expectedPath
								end
							end
						end
					end

					if bestMatch then
						local ok, approved, reconstructed = pcall(function()
							return reconstructAndValidate(bestMatch, message)
						end)
						if not ok then
							warn("[GameState] Error processing broadcast from "..player.Name..": "..tostring(approved))
						elseif not approved then
							warn("[GameState] "..player.Name.."'s broadcast failed validation, discarding")
						else
							bestMatch.node(reconstructed)
						end
					else
						warn("[GameState]", player.Name, "attempted to broadcast a non-broadcastable node")
					end
				end)
				if not entryOk then
					warn("[GameState] Unexpected error processing broadcast entry from "..player.Name..": "..tostring(entryErr))
				end
			end
			PendingBroadcasts[player] = nil
		end
	end)
end)

BroadcastRemote.OnServerEvent:Connect(function(player: Player, queue: { any })
	if not consumeBroadcastToken(player) then
		warn("[GameState] "..player.Name.." exceeded broadcast call rate limit, dropping this call")
		return
	end

	if typeof(queue) ~= "table" then
		warn("[GameState] "..player.Name.." sent a malformed broadcast queue, discarding")
		return
	end

	if not PendingBroadcasts[player] then
		PendingBroadcasts[player] = {}
	end
	local existing = #PendingBroadcasts[player]
	for i, entry in queue do
		if existing + i > MAX_BROADCASTS_PER_PLAYER_PER_FRAME then
			warn("[GameState] "..player.Name.." exceeded broadcast rate limit, dropping excess")
			break
		end
		if typeof(entry) ~= "table" or typeof(entry.path) ~= "table" then
			warn("[GameState] "..player.Name.." sent a malformed broadcast entry, discarding")
			continue
		end
		if #entry.path > MAX_BROADCAST_PATH_LENGTH then
			warn("[GameState] "..player.Name.." sent an oversized broadcast path, discarding")
			continue
		end
		if not isWithinDataLimits(entry.data, MAX_BROADCAST_DATA_DEPTH, MAX_BROADCAST_DATA_NODES, MAX_BROADCAST_STRING_LENGTH) then
			warn("[GameState] "..player.Name.." sent an oversized broadcast payload, discarding")
			continue
		end
		table.insert(PendingBroadcasts[player], entry)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	for node in SyncedNodes do
		local connections = rawget(node, "_syncConnections")
		if connections and connections[player] then
			connections[player]() -- disconnect the Changed subscription
			connections[player] = nil
			if next(connections) == nil then
				SyncedNodes[node] = nil
			end
		end
	end
	for node in BroadcastableNodes do
		local registry = rawget(node, "_broadcastRegistry")
		if registry then
			registry[player] = nil
			if next(registry) == nil then
				BroadcastableNodes[node] = nil
			end
		end
	end
	PendingSync[player] = nil
	PendingBroadcasts[player] = nil
	BroadcastBuckets[player] = nil
end)

return ServerNode
