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
type PendingSyncNode = { value: { path: {any}, value: any }?, children: { [any]: PendingSyncNode }? }
local PendingSync: { [Player]: PendingSyncNode } = {}

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

-- These are tunable via GameState.configure({...}) below rather than editing the locals
-- directly - this module lives inside Packages/ once installed via Wally, and editing the
-- values in place here gets silently overwritten on the next `wally update`.
local Config = {
	-- Frame-level cap on how many broadcast entries a single player can enqueue per
	-- Heartbeat. 20 comfortably covers legitimate UI-driven writes (a settings panel,
	-- inventory drag-drop, a lever pull) while bounding worst-case per-frame processing
	-- cost. Raise it if your game has denser client-write patterns (e.g. real-time
	-- drawing/building tools).
	MAX_BROADCASTS_PER_PLAYER_PER_FRAME = 20,
	MAX_BROADCAST_PATH_LENGTH = 16,
	MAX_BROADCAST_DATA_DEPTH = 16,
	MAX_BROADCAST_DATA_NODES = 500, -- total values walked; bounds cost cheaply, exits early
	-- Max length of any single string value in a payload; MAX_BROADCAST_DATA_NODES counts
	-- table entries, not bytes, so without this a single oversized string leaf would pass
	-- the node-count check untouched.
	MAX_BROADCAST_STRING_LENGTH = 2000,
	-- Token bucket limiting raw BroadcastRemote:FireServer call *frequency*, independent of
	-- payload size/shape - the limits above don't stop a client from calling FireServer
	-- itself extremely rapidly with small/empty payloads, and each call has real
	-- server-side dispatch cost regardless of content. Defaults allow short legitimate
	-- bursts (a flurry of clicks) while capping sustained spam at 5 calls/sec.
	BROADCAST_BUCKET_CAPACITY = 10,
	BROADCAST_BUCKET_REFILL_PER_SECOND = 5,
}

-- Lets a game override any of the limits above without touching library source, e.g.
--   GameState.configure({ MAX_BROADCASTS_PER_PLAYER_PER_FRAME = 40 })
-- Server-only - there's nothing to configure on the client. Unknown keys are ignored with a
-- warning rather than silently accepted, to catch typos.
local function configure(overrides: { [string]: number })
	for key, value in overrides do
		if Config[key] == nil then
			warn("[GameState] configure(): unknown option '"..tostring(key).."', ignoring")
		else
			Config[key] = value
		end
	end
end

local BroadcastBuckets: { [Player]: { tokens: number, lastRefill: number } } = setmetatable({}, {__mode = "k"}) :: any

local function consumeBroadcastToken(player: Player): boolean
	local bucket = BroadcastBuckets[player]
	local now = os.clock()
	if not bucket then
		bucket = { tokens = Config.BROADCAST_BUCKET_CAPACITY, lastRefill = now }
		BroadcastBuckets[player] = bucket
	end
	local elapsed = now - bucket.lastRefill
	if elapsed > 0 then
		bucket.tokens = math.min(Config.BROADCAST_BUCKET_CAPACITY, bucket.tokens + elapsed * Config.BROADCAST_BUCKET_REFILL_PER_SECOND)
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
ServerNode.configure = configure

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
--
-- Dedup uses real path segments as actual table keys (nested one level per segment),
-- not a stringified path. Path segments can be any Luau value - numbers, strings,
-- booleans, or an Instance/table used as a dict key - and Lua's native key equality
-- already handles all of those correctly. Stringifying first would reintroduce exactly
-- the collisions this is meant to avoid: tostring(1) and tostring("1") are both "1", and
-- tostring() on an Instance returns its .Name, which two different Instances can share.
--
-- A tree position can be a leaf (something was written to exactly this path), have
-- children (something was written further down), or both at once in the same frame -
-- so `value` and `children` are kept as separate fields on each node instead of one
-- overwriting the other.
local function queueSync(path: {any}, player: Player, value: any)
	if not PendingSync[player] then
		PendingSync[player] = {}
	end
	local cursor = PendingSync[player]
	for _, key in path do
		if typeof(cursor.children) ~= "table" then
			cursor.children = {}
		end
		if typeof(cursor.children[key]) ~= "table" then
			cursor.children[key] = {}
		end
		cursor = cursor.children[key]
	end
	-- A later write to this exact path replaces the earlier one - only the most recent
	-- value per path needs to reach the client within a single flush.
	cursor.value = { path = path, value = value }
end

local function collectPendingSync(node: PendingSyncNode, out: { any })
	if node.value ~= nil then
		table.insert(out, node.value)
	end
	if node.children then
		for _, child in node.children do
			collectPendingSync(child, out)
		end
	end
end

-- Per-player index of broadcast registrations, keyed by the path segments the client
-- addresses them under (reg.clientPath or reg.path) - same "real path segments as real
-- table keys" trie shape as PendingSync above. This turns matching an incoming broadcast
-- from an O(total registered nodes across the whole game) scan into an O(message path
-- length) walk: registrations only ever need to be found along the exact chain of keys
-- the client sent, nothing else is a candidate.
type BroadcastTrieNode = { registration: any?, children: { [any]: BroadcastTrieNode }? }
local BroadcastTrieRoot: { [Player]: BroadcastTrieNode } = setmetatable({}, {__mode = "k"}) :: any

local function trieInsert(player: Player, path: {any}, registration: any)
	local root = BroadcastTrieRoot[player]
	if not root then
		root = {}
		BroadcastTrieRoot[player] = root
	end
	local cursor = root
	for _, key in path do
		if not cursor.children then
			cursor.children = {}
		end
		if not cursor.children[key] then
			cursor.children[key] = {}
		end
		cursor = cursor.children[key]
	end
	cursor.registration = registration
end

local function trieRemove(player: Player, path: {any})
	local cursor = BroadcastTrieRoot[player]
	if not cursor then
		return
	end
	for _, key in path do
		if not cursor.children or not cursor.children[key] then
			return
		end
		cursor = cursor.children[key]
	end
	cursor.registration = nil
end

-- Walks the player's trie along the message's path, remembering the DEEPEST registration
-- seen along the way - a registration further down the path always wins over one closer
-- to the root, matching the old scan's "longest matching prefix" behavior.
local function trieFindBestMatch(player: Player, path: {any}): any?
	local cursor = BroadcastTrieRoot[player]
	if not cursor then
		return nil
	end
	local best = cursor.registration
	for _, key in path do
		if not cursor.children or not cursor.children[key] then
			break
		end
		cursor = cursor.children[key]
		if cursor.registration then
			best = cursor.registration
		end
	end
	return best
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

		local path = SharedNode.getNodePath(node)
		local registration = {
			node = node,
			validateData = validateData,
			clientPath = clientPath,
			path = clientPath or path,
		}

		if not rawget(node, "_broadcastRegistry") then
			rawset(node, "_broadcastRegistry", {})
		end
		rawget(node, "_broadcastRegistry")[player] = registration
		BroadcastableNodes[node] = true
		trieInsert(player, clientPath or path, registration)
	end

	-- Revokes a player's permission to broadcast-write to this node. Same as removeSync - you
	-- only need this for revoking access from someone still connected; leaving players are
	-- cleaned up automatically.
	node.disallowClientBroadcast = function(player: Player)
		assertIsPlayer(player)
		local registry = rawget(node, "_broadcastRegistry")
		if registry then
			local registration = registry[player]
			registry[player] = nil
			if next(registry) == nil then
				BroadcastableNodes[node] = nil
			end
			if registration then
				trieRemove(player, registration.path)
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

		for player, tree in PendingSync do
			local batch = {}
			collectPendingSync(tree, batch)
			if #batch > 0 then
				SyncRemote:FireClient(player, batch)
			end
			PendingSync[player] = {}
		end

		-- Broadcasting

		for player, queue in PendingBroadcasts do
			for _, message in queue do
				local entryOk, entryErr = pcall(function()
					if typeof(message) ~= "table" or typeof(message.path) ~= "table" then
						warn("[GameState] "..player.Name.." sent a malformed broadcast entry, discarding")
						return
					end

					local bestMatch = trieFindBestMatch(player, message.path)

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
		if existing + i > Config.MAX_BROADCASTS_PER_PLAYER_PER_FRAME then
			warn("[GameState] "..player.Name.." exceeded broadcast rate limit, dropping excess")
			break
		end
		if typeof(entry) ~= "table" or typeof(entry.path) ~= "table" then
			warn("[GameState] "..player.Name.." sent a malformed broadcast entry, discarding")
			continue
		end
		if #entry.path > Config.MAX_BROADCAST_PATH_LENGTH then
			warn("[GameState] "..player.Name.." sent an oversized broadcast path, discarding")
			continue
		end
		if not isWithinDataLimits(entry.data, Config.MAX_BROADCAST_DATA_DEPTH, Config.MAX_BROADCAST_DATA_NODES, Config.MAX_BROADCAST_STRING_LENGTH) then
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
	BroadcastTrieRoot[player] = nil
end)

return ServerNode
