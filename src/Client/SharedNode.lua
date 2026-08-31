--!strict
local HTTPS = game:GetService("HttpService")

-- Changed/KeyChanged callbacks are stored as fields directly ON each node
-- (_changedCallbacks / _keyChangedCallbacks) rather than in an external table
-- keyed by node. This matters: a closure that captures `node` and is stored as
-- a VALUE in an EXTERNAL table that's ALSO weak-keyed BY that same node does not
-- get collected in Luau, even though it structurally looks like the standard
-- "weak key" pattern - the closure holds its own strong reference back to the
-- node, so the weak key never actually loses its only reference. Storing the
-- same closure as a field ON the node itself makes it a self-contained cycle
-- instead (node -> node's own field -> closure -> node), which Luau's
-- cycle-collecting GC handles correctly - the same reason a node's own
-- metatable (which closes over the node) is collectible.

local Node = {}
Node.NIL = setmetatable({}, {
	__tostring = function()
		return "nil"
	end,
})

--[[

***NOTE***
All the types are solely for the user's experience. Properties like
Parent, Key, _isPhantom which the user is not meant to access won't be defined.

Luau's type-checker does not support intersecting a type {[string]: number} with {Changed: function}
and Changed is not recognized as a function. This is why types are being built through the
type function, to avoid having to intersect different types. It's a workaround for that
typechecker limitation, and can likely be simplified if/when Luau's handling of this kind
of intersection changes.

]]

type NoExtra = {}

export type function NodeType(T, Extra)
	local base = types.newtable()

	base:setproperty(types.singleton("NIL"), types.any)

	local disconnect = types.newfunction()
	disconnect:setparameters({})
	disconnect:setreturns({})
	local changedCb = types.newfunction()
	changedCb:setparameters({ T, T })
	changedCb:setreturns({})
	local changed = types.newfunction()
	changed:setparameters({ changedCb })
	changed:setreturns({ disconnect })
	base:setproperty(types.singleton("Changed"), changed)

	local waitForChanged = types.newfunction()
	waitForChanged:setparameters({})
	waitForChanged:setreturns({ T, T })
	base:setproperty(types.singleton("WaitForChanged"), waitForChanged)

	-- Merge in any caller-supplied extra properties (e.g. ServerNode's
	-- addSync/setSync/...) directly onto this SAME table object, so named
	-- properties always take precedence over any indexer added later.
	if Extra then
		for key, prop in Extra:properties() do
			base:setproperty(key, prop.read)
		end
	end

	local function finish()
		local updateFn = types.newfunction()
		updateFn:setparameters({ T })
		updateFn:setreturns({T})

		-- ONE signature, not two intersected ones. node() / node(value) / node(fn)
		-- all go through this single call, with the choice folded into a union
		-- inside the parameter instead of split across overloads.
		local callFn = types.newfunction()
		callFn:setparameters({ types.unionof(types.optional(T), updateFn) })
		callFn:setreturns({T})

		-- .Update kept separately, still its own clean non-overloaded signature,
		-- for cases where you want old to infer without manual annotation.
		local update = types.newfunction()
		update:setparameters({ updateFn })
		update:setreturns({T})
		base:setproperty(types.singleton("Update"), update)

		return types.intersectionof(base, callFn)
	end

	if not T:is("table") then
		return finish()
	end

	local Whole = T
	local indexer = T:indexer()

	local propertyList = {}
	for key, prop in T:properties() do
		table.insert(propertyList, { key = key, ty = prop.read })
	end

	local function unionOrAny(list)
		if #list == 0 then
			return types.any
		elseif #list == 1 then
			return list[1]
		else
			return types.unionof(table.unpack(list))
		end
	end

	local elementParts = {}
	local keyParts = {}
	if indexer then
		table.insert(elementParts, indexer.readresult)
		table.insert(keyParts, indexer.index)
	end
	for _, p in propertyList do
		table.insert(elementParts, p.ty)
		table.insert(keyParts, p.key)
	end

	local Element = unionOrAny(elementParts)
	local Key = unionOrAny(keyParts)

	local function arrayOf(elementType)
		local arr = types.newtable()
		arr:setindexer(types.number, elementType)
		return arr
	end

	-- KeyChanged
	local disconnect1 = types.newfunction()
	disconnect1:setparameters({})
	disconnect1:setreturns({})
	local keyChangedCb = types.newfunction()
	keyChangedCb:setparameters({ Key, Element, Element })
	keyChangedCb:setreturns({})
	local keyChanged = types.newfunction()
	keyChanged:setparameters({ keyChangedCb })
	keyChanged:setreturns({ disconnect1 })
	base:setproperty(types.singleton("KeyChanged"), keyChanged)

	-- ChildAdded
	local disconnect2 = types.newfunction()
	disconnect2:setparameters({})
	disconnect2:setreturns({})
	local childAddedCb = types.newfunction()
	childAddedCb:setparameters({ Key, Element })
	childAddedCb:setreturns({})
	local childAdded = types.newfunction()
	childAdded:setparameters({ childAddedCb })
	childAdded:setreturns({ disconnect2 })
	base:setproperty(types.singleton("ChildAdded"), childAdded)

	-- ChildRemoved
	local disconnect3 = types.newfunction()
	disconnect3:setparameters({})
	disconnect3:setreturns({})
	local childRemovedCb = types.newfunction()
	childRemovedCb:setparameters({ Key, Element })
	childRemovedCb:setreturns({})
	local childRemoved = types.newfunction()
	childRemoved:setparameters({ childRemovedCb })
	childRemoved:setreturns({ disconnect3 })
	base:setproperty(types.singleton("ChildRemoved"), childRemoved)

	-- Merge
	local mergeInput = types.newtable()
	mergeInput:setindexer(Key, Element)
	local merge = types.newfunction()
	merge:setparameters({ mergeInput })
	merge:setreturns({ Whole })
	base:setproperty(types.singleton("Merge"), merge)

	-- WaitForKeyChanged
	local waitForKeyChanged = types.newfunction()
	waitForKeyChanged:setparameters({})
	waitForKeyChanged:setreturns({ Key, Element, Element })
	base:setproperty(types.singleton("WaitForKeyChanged"), waitForKeyChanged)

	-- WaitForChildAdded
	local waitForChildAdded = types.newfunction()
	waitForChildAdded:setparameters({})
	waitForChildAdded:setreturns({ Key, Element })
	base:setproperty(types.singleton("WaitForChildAdded"), waitForChildAdded)

	-- WaitForChildRemoved
	local waitForChildRemoved = types.newfunction()
	waitForChildRemoved:setparameters({})
	waitForChildRemoved:setreturns({ Key, Element })
	base:setproperty(types.singleton("WaitForChildRemoved"), waitForChildRemoved)

	-- Keys
	local keys = types.newfunction()
	keys:setparameters({})
	keys:setreturns({ arrayOf(Key) })
	base:setproperty(types.singleton("Keys"), keys)

	-- GetIndex
	local getIndex = types.newfunction()
	getIndex:setparameters({ Element })
	getIndex:setreturns({ types.unionof(Key, arrayOf(Key), types.singleton(nil)) })
	base:setproperty(types.singleton("GetIndex"), getIndex)

	-- Array-only functions: only when array-shaped (numeric indexer)
	if indexer and indexer.index:is("number") then
		local insertFn = types.newfunction()
		insertFn:setparameters({ Element })
		insertFn:setreturns({ Whole })
		base:setproperty(types.singleton("Insert"), insertFn)

		local removeValueFn = types.newfunction()
		removeValueFn:setparameters({ Element, types.unionof(types.number, types.singleton(nil)) })
		removeValueFn:setreturns({ Whole })
		base:setproperty(types.singleton("RemoveValue"), removeValueFn)

		local removeIndexFn = types.newfunction()
		removeIndexFn:setparameters({ types.number })
		removeIndexFn:setreturns({ Whole })
		base:setproperty(types.singleton("RemoveIndex"), removeIndexFn)
	end

	-- Recursive children — always pass Extra along, 2 args
	for _, p in propertyList do
		base:setproperty(p.key, NodeType(p.ty, Extra))
	end
	if indexer then
		base:setindexer(indexer.index, NodeType(indexer.readresult, Extra))
	end

	return finish()
end

export type Node<T> = NodeType<T, NoExtra>

local function compareData(t1: any, t2: any)
	if typeof(t1) ~= typeof(t2) then return false end
	if typeof(t1) ~= "table" then
		return t1 == t2
	end
	for i, v in t1 do
		if not compareData(v, t2[i]) then
			return false
		end
	end
	for i, v in t2 do
		if not compareData(v, t1[i]) then
			return false
		end
	end
	return true
end

Node.compareData = compareData

local function anyAncestorSubscribed(node: any): boolean
	local cur = node
	while cur do
		if rawget(cur, "_changedCallbacks") or rawget(cur, "_keyChangedCallbacks") then
			return true
		end
		cur = cur.Parent
	end
	return false
end

local function getNodePath(node: any): {any}
	local path = {}
	local n = node
	while n and n.Parent do
		table.insert(path, 1, n.Key)
		n = n.Parent
	end
	return path
end

Node.getNodePath = getNodePath

local function getTableType(data: {[any]: any}): "any" | "array" | "dict"
	local count = 0
	for _ in data do
		count += 1
	end
	if count == 0 then
		return "any"
	end
	if count == #data then
		return "array"
	end
	return "dict"
end

-- Used only to describe a table in an error message. JSONEncode itself can throw
-- (Instances, NaN/inf, some mixed-key shapes), which would otherwise mask the
-- actual error we're trying to report with a confusing unrelated crash.
local function safeDescribeTable(data: {[any]: any}): string
	local ok, encoded = pcall(function()
		return HTTPS:JSONEncode(data)
	end)
	if ok then
		return encoded
	end
	return tostring(data)
end


local DetachedChildren: any = setmetatable({}, {__mode = "k"})

local function rememberDetached(parent: any, key: any, node: any)
	local bucket = DetachedChildren[parent]
	if not bucket then
		bucket = setmetatable({}, {__mode = "v"})
		DetachedChildren[parent] = bucket
	end
	bucket[key] = node
end

local function recallDetached(parent: any, key: any): any?
	local bucket = DetachedChildren[parent]
	if not bucket then
		return nil
	end
	return bucket[key]
end

local function shouldDetach(node: any): boolean
	if not rawget(node, "_isPhantom") then
		return false -- directly, legitimately written to at some point (even with {}) - never prune
	end
	local c = node.content
	if c == nil then
		return true
	end
	if typeof(c) == "table" and next(c) == nil then
		return true -- phantom, and holds no real descendant structure either
	end
	return false -- phantom itself, but has real children hanging off it - leave it; cascade handles them individually
end

local function detachNode(node: any)
	local parent = rawget(node, "Parent")
	if not parent or rawget(node, "_isDetached") then
		return -- root node, or already detached - nothing to do
	end
	local parentContent = parent.content
	if parentContent and parentContent[node.Key] == node then
		parentContent[node.Key] = nil
		parent.content = parentContent
	end
	node.content = nil
	node._isDetached = true
	rememberDetached(parent, node.Key, node)
	-- Cascade upward: the parent may now be empty too
	if shouldDetach(parent) then
		detachNode(parent)
	end
end

local function reattachNode(node: any)
	if not rawget(node, "_isDetached") then
		return
	end
	local parent = rawget(node, "Parent")
	if parent then
		reattachNode(parent) -- make sure the whole chain above is attached first
		if not parent.content then
			parent.content = {}
		end
		parent.content[node.Key] = node
	end
	node._isDetached = nil
end

local function clearPhantomChain(node: any)
	local n = node
	while n and rawget(n, "_isPhantom") do
		n._isPhantom = nil
		n = rawget(n, "Parent")
	end
end

Node.clearPhantomChain = clearPhantomChain

-- Internal constructor for a single node - end users don't normally call this directly.
-- The actual GameState root gets created once, automatically, when the module is required
-- (see Server.lua / Client.lua). Every other node in the tree gets created lazily and
-- automatically the first time you access a path that doesn't exist yet, e.g. reading or
-- writing GameState.Players[userId] for the first time creates that node on the spot -
-- you never need to manually "declare" a path before using it.
function Node.new<T>(key: any, data: T, decorate: ((any) -> ())?) : Node<T>
	local content : any = {}
	local isPhantom = (data == nil)
	local newNode = setmetatable({}, {
		__index = function(t: any, i)
			-- Check if we are trying to access a function
			if typeof(rawget(t, i)) == "function" then
				return rawget(t, i)
			end

			-- Check if we are trying to access the NodeTypeBase property directly
			if i == "content" then
				return rawget(t, "content")
			elseif i == "Key" then
				return rawget(t, "Key")
			elseif i == "Parent" then
				return rawget(t, "Parent")
			end

			-- We are now trying to access another node. This is only possible if the current node is
			-- a table, or is currently empty (nil), since an empty node is allowed to become a parent
			if t.content ~= nil and typeof(t.content) ~= "table" then
				t.content = {}
				--error("[GameState] Trying to index a "..typeof(content).." ("..tostring(content)..") with "..tostring(i))
				--return nil
			end
			-- If this node has no content yet, promote it into a parent table so it can hold children
			if t.content == nil then
				t.content = {}
			end
			-- If the index exists in the table, return the node it corresponds to
			if t.content[i] ~= nil then
				return t.content[i]
			end

			local existing = recallDetached(t, i)
			if existing then
				return existing
			end

			-- If we reach this points it means we are trying to access a node that doesn't exist.
			-- We need to create the node and initialize it with nil
			local child = Node.new(i, nil, decorate)
			child.Parent = t
			t.content[i] = child
			task.defer(function()
				if shouldDetach(child) then
					detachNode(child)
				end
			end)
			return child
		end,
		-- Every node in the tree is called like a function to read or write it:
		--   GameState.Players[userId].Coins()        -- read: returns the current value (nil if never set)
		--   GameState.Players[userId].Coins(100)      -- write: sets the value to 100
		--   GameState.Players[userId].Coins(nil)      -- write: explicitly clears it (this is different
		--                                                 from just not calling it - see below)
		--   GameState.Players[userId].Coins(function(old) return old + 1 end)
		--                                              -- write: pass a function to update based on the
		--                                                 current value instead of reading, then writing
		--
		-- Reading a table-shaped node returns a plain Lua table snapshot, not a live reference -
		-- mutating the table you get back does NOT change the stored state. Write it back explicitly
		-- (or use Merge/Insert/RemoveValue/RemoveIndex below) if you want the change to stick.
		--
		-- IMPORTANT TIMING NOTE: Changed/KeyChanged callbacks (see below) fire BEFORE the write is
		-- actually applied internally. The `old`/`new` values passed into your callback are correct,
		-- but if your callback ignores those and calls the node again to read it fresh
		-- (e.g. GameState.Players[userId].Coins() from inside a Coins.Changed callback), you'll get
		-- the OLD value, not the one that's about to be written. Always use the arguments the
		-- callback gives you instead of re-reading the node from inside it.
		__call = function(t: any, ...)
			-- Use select("#", ...) instead of checking the argument's value, so that
			-- GameState.a(nil) (explicit write of nil) is distinguishable from GameState.a() (read)
			local argCount = select("#", ...)
			if argCount > 0 then -- Writing to the node - change its content
				reattachNode(t)
				local data: any, firedKeyChangedCbs: {any}?,
				firedChangedCbs: {any}? = ...
				firedKeyChangedCbs = firedKeyChangedCbs or {}
				firedChangedCbs = firedChangedCbs or {}

				-- Change content
				local oldData = t()

				if typeof(data) == "function" then
					local cur = t()
					data = data :: any -- Otherwise it threw an error
					data = data(cur)
				end

				-- Fire KeyChanged / Changed subscriptions - skip the (expensive) ancestor
				-- snapshot walk entirely if nothing from here to the root is subscribed
				local hasSubscribers = not compareData(oldData, data) and anyAncestorSubscribed(t)

				-- Fire KeyChanged subscriptions

				if hasSubscribers then
					local child = t
					local parent = t.Parent
					local childNewData = data
					local childOldData = oldData

					while parent do
						local parentKeyChangedCbs = rawget(parent, "_keyChangedCallbacks")
						if parentKeyChangedCbs then
							for _, callback in parentKeyChangedCbs do
								if not table.find(firedKeyChangedCbs, callback) then
									callback(child.Key, childOldData, childNewData)
									table.insert(firedKeyChangedCbs, callback)
								end
							end
						end

						parent = parent :: any

						local parentSnapshot = parent()
						local parentNewSnapshot = if parentSnapshot then table.clone(parentSnapshot) else {}
						parentNewSnapshot[child.Key] = childNewData
						childNewData = parentNewSnapshot

						local parentOldSnapshot = if parentSnapshot then table.clone(parentSnapshot) else nil
						if parentOldSnapshot ~= nil then
							parentOldSnapshot[child.Key] = childOldData
						end
						childOldData = parentOldSnapshot

						child = parent
						parent = parent.Parent
					end
				end

				-- Fire Changed subscriptions

				if hasSubscribers then
					local curNode = t
					local curNewData = data

					while curNode do
						curNode = curNode :: any
						local curOldData = curNode()
						if typeof(curNode.content) == "table" then
							for i,v in curNode.content or {} do
								if rawget(v, "_isPhantom") then
									curOldData[i] = nil
								end
							end
						end
						if rawget(curNode, "_isPhantom") then
							curOldData = nil
						end
						local curChangedCbs = rawget(curNode, "_changedCallbacks")
						if curChangedCbs then
							for _, callback in curChangedCbs do
								if not table.find(firedChangedCbs, callback) then
									callback(curOldData, curNewData)
									table.insert(firedChangedCbs, callback)
								end
							end
						end

						if curNode.Parent then
							curNode = curNode :: any
							local tempData = curNode.Parent() or {}
							tempData[curNode.Key] = curNewData
							curNewData = tempData
						end
						curNode = curNode.Parent
					end
				end

				if data == nil then
					-- Explicitly clear this node back to empty
					t.content = nil
					detachNode(t)
				elseif typeof(data) ~= "table" then
					t.content = data
				else
					for i,v in data do
						t[i](v, table.clone(firedKeyChangedCbs), table.clone(firedChangedCbs))
					end
					-- Remove removed keys
					if typeof(oldData) == "table" then
						for i,v in oldData do
							if not data[i] then
								t[i](nil, table.clone(firedKeyChangedCbs), table.clone(firedChangedCbs))
							end
						end
					end
				end

				if data ~= nil then
					clearPhantomChain(t)
				end

				return data
			else -- Reading the node - getting and converting its content
				if typeof(t.content) ~= "table" then
					-- Returns nil naturally if the node was never written to - no sentinel needed
					return t.content
				end
				local result = {}
				for i, v in t.content do -- Call the nodes to read them
					result[i] = v()
				end
				--[[if next(result) == nil and (t._isPhantom or t._isDetached) then
					return nil
				end--]]
				return result
			end
		end,
	})

	if typeof(data) ~= "table" then
		content = data
	else
		for i, v in pairs(data) do
			content[i] = Node.new(i, v, decorate)
			content[i].Parent = newNode
		end
	end

	newNode.content = content
	newNode.Key = key
	newNode._isPhantom = isPhantom

	-- Shorthand for the "update based on current value" write style:
	--   GameState.Players[userId].Coins.Update(function(old) return old + 1 end)
	-- is exactly the same as:
	--   GameState.Players[userId].Coins(function(old) return old + 1 end)
	-- Use whichever reads better to you - they're identical.
	newNode.Update = function(fn)
		return newNode(fn)
	end

	-- Fires whenever any DIRECT CHILD of this node changes - added, removed, or its value
	-- changed. You get the child's key, its old value, and its new value.
	--   GameState.Players[userId].Inventory.KeyChanged(function(itemId, oldQty, newQty)
	--       print(itemId, "went from", oldQty, "to", newQty)
	--   end)
	-- Only fires for DIRECT children, not grandchildren - if you need to know about changes
	-- deeper in the tree, subscribe KeyChanged on the node at that specific level, or use
	-- Changed (below) on the node you actually care about.
	-- Returns a disconnect function - call it to stop listening:
	--   local disconnect = someNode.KeyChanged(function(...) ... end)
	--   disconnect()
	newNode.KeyChanged = function(callback: (any, T, T) -> ())
		-- Safeguards

		local data = newNode()
		if data == nil then
			data = {}
		end

		local dataType = typeof(data)
		if dataType ~= "table" then
			error("[GameState] KeyChanged can only be used on a table-shaped node,"..
				"got "..dataType..": "..tostring(data))
		end

		-- Logic

		-- A live subscription means this node is no longer "idle" - don't let the
		-- auto-detach mechanism prune it out from under the subscriber before it
		-- ever gets a chance to fire.
		clearPhantomChain(newNode)

		local createdSubscription

		if not rawget(newNode, "_keyChangedCallbacks") then
			rawset(newNode, "_keyChangedCallbacks", {})
		end
		table.insert(rawget(newNode, "_keyChangedCallbacks"), callback)

		local disconnect = function()
			local callbacks = rawget(newNode, "_keyChangedCallbacks")
			if not callbacks then
				return
			end
			table.remove(callbacks, table.find(callbacks, callback))
			if #callbacks == 0 then
				rawset(newNode, "_keyChangedCallbacks", nil)
			end
		end

		return disconnect
	end

	-- Fires only when a NEW direct child appears under this node (goes from not existing to
	-- having a value) - a filtered version of KeyChanged that ignores everything except "brand
	-- new key showed up".
	--   GameState.Players.ChildAdded(function(userId, playerData)
	--       print(userId, "joined with", playerData)
	--   end)
	-- Returns a disconnect function, same as KeyChanged.
	newNode.ChildAdded = function(callback: (any, T) -> ())
		-- Safeguards

		local data = newNode()
		if data == nil then
			data = {}
		end

		local dataType = typeof(data)
		if dataType ~= "table" then
			error("[GameState] ChildAdded can only be used on a table-shaped node,"..
				"got "..dataType..": "..tostring(data))
		end

		-- Logic

		local createdSubscription = newNode.KeyChanged(function(key, old, new)
			if old == nil and new ~= nil then
				callback(key, new)
			end
		end)

		local disconnect = function()
			createdSubscription()
		end

		return disconnect
	end

	-- The mirror of ChildAdded: fires only when a direct child goes from having a value to
	-- being cleared (existed, then got set to nil).
	--   GameState.Players.ChildRemoved(function(userId, lastKnownData)
	--       print(userId, "left, last data was", lastKnownData)
	--   end)
	-- Returns a disconnect function, same as KeyChanged.
	newNode.ChildRemoved = function(callback: (any, T) -> ())
		-- Safeguards

		local data = newNode()
		if data == nil then
			data = {}
		end

		local dataType = typeof(data)
		if dataType ~= "table" then
			error("[GameState] ChildRemoved can only be used on a table-shaped node,"..
				"got "..dataType..": "..tostring(data))
		end

		-- Logic

		local createdSubscription = newNode.KeyChanged(function(key, old, new)
			if old ~= nil and new == nil then
				callback(key, old)
			end
		end)

		local disconnect = function()
			createdSubscription()
		end

		return disconnect
	end

	-- Fires whenever THIS node's own value changes - not its children individually, but the
	-- node as a whole (so writing any nested value under it will also fire this, with `old`/`new`
	-- as full snapshots of everything under this node before/after).
	--   GameState.Players[userId].Inventory.Changed(function(old, new)
	--       print("inventory changed from", old, "to", new)
	--   end)
	-- Use Changed when you care about "did anything under here change at all". Use KeyChanged
	-- when you specifically want to know WHICH direct child changed. Returns a disconnect
	-- function, same as KeyChanged. Remember the timing note above the read/write section:
	-- inside this callback, use the `old`/`new` arguments - don't re-read the node itself.
	newNode.Changed = function(callback : (T, T) -> ())
		-- Same reasoning as KeyChanged above: a live subscriber means this node
		-- isn't idle, even if nothing's been written to it yet.
		clearPhantomChain(newNode)

		if not rawget(newNode, "_changedCallbacks") then
			rawset(newNode, "_changedCallbacks", {})
		end

		table.insert(rawget(newNode, "_changedCallbacks"), callback)

		local disconnect = function()
			local callbacks = rawget(newNode, "_changedCallbacks")
			if not callbacks then
				return
			end
			table.remove(callbacks, table.find(callbacks, callback))
			if #callbacks == 0 then
				rawset(newNode, "_changedCallbacks", nil)
			end
		end

		return disconnect
	end

	-- Shallow-merges the given table into this node's current table value, overwriting any
	-- keys you provide and leaving everything else untouched. This is the easy way to update a
	-- few fields without having to read the whole thing, modify it, and write it all back.
	--   GameState.Players[userId].Settings.Merge({volume = 50})
	-- If Settings was {volume = 100, brightness = 80}, it's now {volume = 50, brightness = 80}.
	-- Only merges one level deep - it does NOT recursively merge nested tables inside the
	-- values you pass. Only works on nodes that are currently table-shaped (or empty/unset).
	newNode.Merge = function(t: {any})
		-- Safeguards

		local data = newNode()
		if data == nil then
			data = {}
		end

		local dataType = typeof(data)
		if dataType ~= "table" then
			error("[GameState] Merge can only be used on a table-shaped node,"..
				"got "..dataType..": "..tostring(data))
		end

		-- Logic

		for i,v in t do
			if v == Node.NIL then
				v = nil
			end
			data[i] = v
		end
		newNode(data)
		return data
	end

	newNode.WaitForChanged = function(): (T, T)
		local thread = coroutine.running()
		local disconnect
		disconnect = newNode.Changed(function(old, new)
			disconnect()
			task.spawn(thread, old, new)
		end) :: any
		return coroutine.yield()
	end

	newNode.WaitForKeyChanged = function(): (any, T, T)

		-- Safeguards

		local data = newNode()
		if data == nil then
			data = {}
		end

		local dataType = typeof(data)
		if dataType ~= "table" then
			error("[GameState] WaitForKeyChanged can only be used on a table-shaped node,"..
				"got "..dataType..": "..tostring(data))
		end

		-- Logic

		local thread = coroutine.running()
		local disconnect
		disconnect = newNode.KeyChanged(function(key, old, new)
			disconnect()
			task.spawn(thread, key, old, new)
		end) :: any
		return coroutine.yield()
	end

	newNode.WaitForChildAdded = function(): (any, T)

		-- Safeguards

		local data = newNode()
		if data == nil then
			data = {}
		end

		local dataType = typeof(data)
		if dataType ~= "table" then
			error("[GameState] WaitForChildAdded can only be used on a table-shaped node,"..
				"got "..dataType..": "..tostring(data))
		end

		-- Logic

		local thread = coroutine.running()
		local disconnect
		disconnect = newNode.ChildAdded(function(key, new)
			disconnect()
			task.spawn(thread, key, new)
		end) :: any
		return coroutine.yield()
	end

	newNode.WaitForChildRemoved = function(): (any, T)

		-- Safeguards

		local data = newNode()
		if data == nil then
			data = {}
		end

		local dataType = typeof(data)
		if dataType ~= "table" then
			error("[GameState] WaitForChildRemoved can only be used on a table-shaped node,"..
				"got "..dataType..": "..tostring(data))
		end

		-- Logic

		local thread = coroutine.running()
		local disconnect
		disconnect = newNode.ChildRemoved(function(key, old)
			disconnect()
			task.spawn(thread, key, old)
		end) :: any
		return coroutine.yield()
	end

	newNode.Keys = function()

		-- Safeguards

		local data = newNode()
		if data == nil then
			data = {}
		end

		local dataType = typeof(data)
		if dataType ~= "table" then
			error("[GameState] Keys can only be used on a table-shaped node,"..
				"got "..dataType..": "..tostring(data))
		end

		-- Logic

		local keys = {}
		for i,v in data do
			table.insert(keys, i)
		end
		return keys
	end

	newNode.GetIndex = function(value: any)

		-- Safeguards

		local data = newNode()
		if data == nil then
			data = {}
		end

		local dataType = typeof(data)
		if dataType ~= "table" then
			error("[GameState] GetIndex can only be used on a table-shaped node,"..
				"got "..dataType..": "..tostring(data))
		end

		-- Logic

		local keys = {}
		for i,v in data do
			if compareData(v, value) then
				table.insert(keys, i)
			end
		end
		if #keys == 0 then
			return nil
		end
		if #keys == 1 then
			return keys[1]
		end

		keys = keys :: any
		return keys
	end

	-- Appends a value to the end of an array-shaped node - the table-friendly version of
	-- table.insert.
	--   GameState.Players[userId].Inventory.Items.Insert("Sword")
	-- Only works on nodes that are currently array-shaped (or empty/unset) - calling it on a
	-- dict-shaped node (one with named keys) throws a clear error instead of silently
	-- corrupting your data.
	newNode.Insert = function(value: T)

		-- Safeguards

		local data = newNode()
		if data == nil then
			data = {}
		end

		local dataType = typeof(data)
		if dataType ~= "table" then
			error("[GameState] Insert can only be used on an array-shaped node,"..
				"got "..dataType..": "..tostring(data))
		end
		local tableDataType = getTableType(data)
		if tableDataType == "dict" then
			error("[GameState] Insert can only be used on an array-shaped node,"..
				"got "..tableDataType..": "..safeDescribeTable(data))
		end

		-- Logic

		table.insert(data, value)
		newNode(data)
		return data
	end

	-- Removes matching VALUES (not positions) from an array-shaped node, up to `amount` times
	-- (defaults to removing every match if you don't pass amount).
	--   GameState.Players[userId].Inventory.Items.RemoveValue("Sword")       -- removes every "Sword"
	--   GameState.Players[userId].Inventory.Items.RemoveValue("Sword", 1)    -- removes just the first one
	-- If you already know the position instead of the value, use RemoveIndex below - it's more
	-- direct and doesn't need to search.
	newNode.RemoveValue = function(value: T, amount: number?)

		-- Safeguards

		local data = newNode()
		if data == nil then
			data = {}
		end

		local dataType = typeof(data)
		if dataType ~= "table" then
			error("[GameState] RemoveValue can only be used on an array-shaped node,"..
				"got "..dataType..": "..tostring(data))
		end
		local tableDataType = getTableType(data)
		if tableDataType == "dict" then
			error("[GameState] RemoveValue can only be used on an array-shaped node,"..
				"got "..tableDataType..": "..safeDescribeTable(data))
		end

		-- Logic

		amount = amount or 1

		local index
		for i,v in data do
			if compareData(v, value) then
				index = i
				break
			end
		end

		local count = 0
		while index and count < amount do
			if not index then break end
			table.remove(data, index)
			count += 1

			index = nil
			for i,v in data do
				if compareData(v, value) then
					index = i
					break
				end
			end
		end

		newNode(data)
		return data
	end

	-- Removes whatever's at a specific position in an array-shaped node - the table-friendly
	-- version of table.remove.
	--   GameState.Players[userId].Inventory.Items.RemoveIndex(1)   -- removes the first item
	-- Throws a clear error if the index is out of range, instead of Luau's default cryptic
	-- "position out of bounds" error - so wrap this in pcall if the index came from somewhere
	-- you're not 100% sure is still valid (e.g. a stale UI reference).
	newNode.RemoveIndex = function(index: number)

		-- Safeguards

		local data = newNode()
		if data == nil then
			data = {}
		end

		local dataType = typeof(data)
		if dataType ~= "table" then
			error("[GameState] RemoveIndex can only be used on an array-shaped node,"..
				"got "..dataType..": "..tostring(data))
		end
		local tableDataType = getTableType(data)
		if tableDataType == "dict" then
			error("[GameState] RemoveIndex can only be used on an array-shaped node,"..
				"got "..tableDataType..": "..safeDescribeTable(data))
		end
		if index < 1 or index > #data then
			error(("[GameState] RemoveIndex: index %d is out of bounds for an array of length %d")
				:format(index, #data))
		end

		-- Logic

		table.remove(data, index)
		newNode(data)
		return data
	end

	if decorate then
		decorate(newNode)
	end

	return (newNode :: any) :: Node<T>
end

return Node
