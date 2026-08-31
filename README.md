# GameState

[![Wally](https://img.shields.io/badge/wally-venignuss%2Fgamestate-purple)](https://wally.run/package/venignuss/gamestate)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](LICENSE)

A single source of truth for your game's state, shared between server and client, with built-in replication and safe client-to-server writes.

## Why this exists

Most Roblox games end up with state scattered across a dozen different systems — some in `DataStore`, some in loose tables, some replicated by hand through `RemoteEvent`s, some only living on the client. Every new feature means wiring up another remote, another `WaitForChild`, another place bugs can hide.

`GameState` collapses all of that into one nested structure you read and write like a plain Lua table. You don't design a schema up front — you just start reading and writing paths, and the structure builds itself as you go, replicating to clients and accepting safe writes back automatically:

```lua
GameState.Round.TimeRemaining(120)
print(GameState.Round.TimeRemaining()) --> 120
```

## GameState vs. player data / persistence libraries

`GameState` is **not** a player data management library, and it's not a replacement for things like ProfileService or Scribe. Those libraries solve a different problem: getting a player's data reliably into and out of `DataStore`: session-locking, retries, versioning/migrations, save-on-leave, and so on. `GameState` doesn't touch `DataStore` at all and has no concept of a "player profile."

What `GameState` solves is **replication and controlled client writes for whatever's currently in memory** — server-authoritative state that needs to live on clients too, and sometimes accept writes back from them. That's a layer above persistence, not a substitute for it. Plenty of what you'd put in `GameState` is round-scoped or otherwise never needs to touch a `DataStore` at all — a door being open, a boss's current health, how much time is left, who's currently in a party.

The two work well together when you do have persistent data: load a player's profile with your persistence library of choice when they join, mirror the fields you want live and replicated into `GameState` (e.g. `GameState.Players[player.UserId].Coins(profile.Data.Coins)`), let `GameState` handle sync/broadcast for the rest of the session, and read back from it whenever the profile needs to save.

## Install

**Wally**

Add it to your `wally.toml`:

```toml
[dependencies]
GameState = "venignuss/gamestate@0.1.0"
```

Then:

```bash
wally install
```

This drops the package into your `Packages` folder. If you don't already have a Rojo setup that syncs `Packages` into your game, see [Rojo's docs](https://rojo.space/docs/) — most Wally-based projects sync it into `ReplicatedStorage.Packages`.

**Manual**

Copy the `src/` contents into a ModuleScript named `GameState` in `ReplicatedStorage`, matching the folder structure (`Client/` and `Server/` as sub-ModuleScripts).

## Quick start

**Server** (anywhere in server-side code, after requiring the module):

```lua
local GameState = require(path.to.GameState)

-- Somewhere that sets a zone up (e.g. when a level loads)
GameState.Zones[zoneId].DoorOpen(false)

-- When a player enters this zone (via a trigger, region check, whatever you use)
local function onPlayerEnteredZone(player, zoneId)
    -- Replicate this zone's state to them
    GameState.Zones[zoneId].addSync(player)

    -- Let anyone standing in this zone pull the lever to open the door -
    -- but only open it, never close it, from the client
    GameState.Zones[zoneId].DoorOpen.allowClientBroadcast(player, function(isOpen)
        return isOpen == true
    end)
end
```

**Client** (in a LocalScript, after requiring the same module):

```lua
local GameState = require(path.to.GameState)
local zoneId = "Vault"

print(GameState.Zones[zoneId].DoorOpen())  -- reads whatever the server has synced so far

GameState.Zones[zoneId].DoorOpen.Changed(function(old, new)
    print("Door", zoneId, new and "opened" or "closed")
end)

-- Pull the lever
GameState.Zones[zoneId].DoorOpen(true)
GameState.Zones[zoneId].DoorOpen.broadcastToServer()
```

The module figures out on its own whether it's running on the server or the client and gives you the right version — you always just `require` the same thing.

## The mental model

Every point in the tree — `GameState`, `GameState.Zones`, `GameState.Zones[someId].DoorOpen` — is a **node**. A node is called like a function to read or write it:

```lua
node()          -- read: returns the current value (nil if it was never set)
node(100)       -- write: sets the value to 100
node(nil)       -- write: explicitly clears it
node(function(old) return old + 1 end)  -- write: update based on the current value
```

Indexing into a node with `.` or `[]` gets you the child node at that key, creating it on the spot if it doesn't exist yet:

```lua
GameState.Zones[zoneId].Chest.Items[1]("Sword")
```

You never "declare" `Zones`, then `[zoneId]`, then `Chest`, then `Items` — you just write to the full path and every level along the way gets created automatically.

Reading a node that holds a table gives you back a **plain Lua table snapshot**, not a live reference. Changing that table doesn't change what's stored — write it back (or use `Merge`/`Insert`/`RemoveValue`/`RemoveIndex`, see below) if you want the change to stick:

```lua
local items = GameState.Zones[zoneId].Chest.Items()
table.insert(items, "Shield")   -- this does nothing to the actual stored state
GameState.Zones[zoneId].Chest.Items(items)  -- this is what actually saves it
```

## Function reference

### Reading and writing (available everywhere)

Every node supports these — see "The mental model" above for the details.

- **`node()`** — read the current value.
- **`node(value)`** — write a value.
- **`node(nil)`** — explicitly clear the value.
- **`node(fn)`** — write based on the current value: `fn` receives the old value and its return becomes the new value.
- **`node.Update(fn)`** — identical to `node(fn)`, just reads more clearly at a glance when that's all you're doing.

### Subscriptions (available everywhere)

All of these return a **disconnect function** — call it to stop listening:

```lua
local disconnect = GameState.Round.TimeRemaining.Changed(function(old, new) end)
disconnect()
```

- **`node.Changed(callback)`** — fires whenever this node's value changes at all, including changes to anything nested under it. `callback(old, new)`.
- **`node.KeyChanged(callback)`** — fires when a *direct* child of this node is added, removed, or changed. `callback(key, old, new)`. Doesn't fire for grandchildren — subscribe at the level you actually care about.
- **`node.ChildAdded(callback)`** — fires only when a direct child goes from not existing to existing. `callback(key, newValue)`.
- **`node.ChildRemoved(callback)`** — fires only when a direct child goes from existing to being cleared. `callback(key, lastValue)`.

**Timing to know about:** these callbacks fire *before* the write is actually applied internally. The `old`/`new` values you're given are correct, but if your callback ignores those and reads the node again itself (`GameState.Round.TimeRemaining()` from inside that same `TimeRemaining.Changed` callback), you'll get the *old* value, not the one being written. Always use the arguments the callback hands you.

### Bulk mutation helpers (available everywhere)

- **`node.Merge(table)`** — shallow-merges a table into the current value, overwriting the keys you give it and leaving everything else alone. One level deep only.
- **`node.Insert(value)`** — appends to an array-shaped node.
- **`node.RemoveValue(value, amount?)`** — removes matching *values* from an array-shaped node, up to `amount` times (removes every match if you don't pass `amount`).
- **`node.RemoveIndex(index)`** — removes whatever's at a specific *position* in an array-shaped node. Throws a clear error if the index is out of range.

All four only work on nodes that are currently array- or table-shaped (or empty/unset) — calling `Insert` on a node with named keys, for example, throws instead of corrupting your data.

### Server-only: replication and client writes

- **`node.addSync(player)`** (or a list of players) — starts pushing this node's value, and every future change to it, to that player's client. Call this to get *anything* from server to client at all — nothing replicates unless you explicitly `addSync` it.
- **`node.removeSync(player)`** — stops syncing to a player who's still connected. **You don't need this for players who are leaving** — see below.
- **`node.setSync(players)`** — sets the exact list of who should be synced, adding and removing as needed in one call. Handy for things like a party or team roster that changes as a whole.
- **`node.allowClientBroadcast(player, validateData?, clientPath?)`** — the *only* way a client can get data into server-trusted state. The client calls `broadcastToServer()` on their end; you decide here whether to accept it. `validateData(value)` should return `true` to accept the write or `false`/`nil` to reject it.

  `clientPath` is optional, and only needed if the path the client will use to address this node doesn't match its real path server-side (normally they match, since both sides build the same tree). Pass the path array the client will actually broadcast under, and the server will match incoming writes against that instead of the node's real location — useful if you're deliberately structuring the server tree differently from what the client sees.

- **`node.disallowClientBroadcast(player)`** — revokes that permission for a player who's still connected. Same note as `removeSync` — not needed for players leaving.

### In case you want your server code to be server-only

By default, everything under `GameState` — including `ServerNode.lua` and every `validateData` function you write — lives in `ReplicatedStorage`, which means it's fully visible to any client, decompilable by exploit tools. For most games that's fine. But your `validateData` functions are exactly what an exploiter would want to read: the precise bounds, whitelists, and conditions your server actually enforces. If you'd rather that logic stay invisible, you can move `Server` into `ServerScriptService`, which clients can't see into at all.

If you want to do this:

1. **In Studio, move the `Server` ModuleScript out of `ReplicatedStorage.GameState` and into `ServerScriptService`**, as its own top-level ModuleScript (e.g. `ServerScriptService.GameStateServer`). `Client` and the root `GameState` module stay in `ReplicatedStorage` exactly as they are.

2. **Update the root `GameState` module's `require(script.Server)`.** It currently assumes `Server` is a child of itself — once `Server` moves out, that line no longer resolves. Point it at the new location instead:

   ```lua
   if RunService:IsServer() then
       return require(game:GetService("ServerScriptService").GameStateServer)
   else
       return require(script.Client)
   end
   ```

3. **Update the two relative lookups inside `ServerNode.lua`.** It currently reaches `Client` and `SharedNode` via `script.Parent.Parent.Client`, which assumes `Server` sits right next to `Client` under the same `GameState` folder. That assumption breaks once `Server` moves, so both need to become absolute references instead:

   ```lua
   local ClientFolder = game:GetService("ReplicatedStorage").GameState.Client
   ```

   and the same for the `SharedNode` require at the top of the file.

Everything else in the module works unchanged — this only affects the handful of lines that navigate the tree by relative position.

### Client-only: sending writes to the server

- **`node.broadcastToServer()`** — sends this node's *current* value to the server for consideration. Write locally first so your own client updates immediately, then call this to ask the server to accept the same change:

  ```lua
  GameState.Zones[zoneId].DoorOpen(true)
  GameState.Zones[zoneId].DoorOpen.broadcastToServer()
  ```

  This only does anything if the server called `allowClientBroadcast` for this exact path and player, and only takes effect if `validateData` accepts it — otherwise the server just quietly discards it. It also doesn't apply instantly: it's queued and sent roughly once per frame, not the moment you call it.

## Things to be careful of

- **`validateData` isn't optional in spirit, even though it's optional in the API.** Skipping it means that player can write *anything* correctly-shaped to that path, no restrictions at all. You'll get a warning in the output every time you register a broadcast target without one — treat that warning as a checklist item, not noise to ignore.

- **When a player leaves, you don't need to clean up their sync or broadcast registrations yourself — that's automatic.** Anything set up through `addSync` or `allowClientBroadcast` for that player gets torn down the moment they disconnect. You only need to call `removeSync`/`disallowClientBroadcast` yourself if you want to revoke access from someone who's *still connected*.

  This automatic cleanup is specifically about sync/broadcast *registrations*. It doesn't mean a player's actual data disappears — that's a separate decision you make in your own game logic (e.g. writing `nil` to clear their state, or leaving it in place if you want it to persist for when they rejoin).

- **Reading inside a `Changed`/`KeyChanged` callback can give you stale data — use the arguments instead.** Covered above, but easy to trip on: the callback fires before the internal write completes.

- **A node only ever holds *one* kind of shape at a time — array or dict, not both — and switching shapes on the fly is a common source of confusing bugs.** If a node currently holds an array and you write a dict-shaped table to it (or vice versa), that's a normal write and it'll happily overwrite it — but `Insert`/`RemoveValue`/`RemoveIndex`/`Merge` are shape-specific and will throw if you call the wrong one for what's currently there.

- **Reads return copies, not references.** Grabbing a table with `node()` and mutating it in place does nothing to the stored state — see "The mental model" above.

- **There's a rate limit and a payload size/depth/string-length limit on client broadcasts, by design.** If a client's writes seem to be silently getting dropped, check the server output — rejected broadcasts always log a warning explaining why (rate-limited, oversized, failed validation, etc.), they don't fail silently without a trace. The size limit also caps the length of any individual string value, not just table shape — a single giant string can't be used to smuggle an oversized payload past the node/depth checks.

- **Don't call `broadcastToServer()` in a tight, unthrottled loop.** Nothing stops you locally, and it won't break anything (the server's own limits catch the excess), but it's still wasted client-side memory and network traffic for no benefit — batch your changes and broadcast once.

## Known limitations

- **Reading a table-shaped node walks its entire subtree, every time, with no caching between writes.** A leaf read (`GameState.Round.TimeRemaining()`) is cheap; reading a wide/deep node frequently (e.g. every frame, or in a loop) is not — it rebuilds a fresh snapshot of every descendant on each call. This is fine for the round-scoped/live state GameState is meant for; it's not meant to hold bulk data like large inventories (see "GameState vs. player data / persistence libraries" above). If you need to read a large subtree repeatedly and cheaply, cache the result yourself between writes rather than calling the node on every access.

- **There's no automated test suite yet.** The replication/validation path (rate limiting, size/depth/string-length checks, `validateData`) is the part most worth testing before relying on this in a live game — if you're evaluating GameState for production use, read that code yourself rather than taking the comments on faith, and contributions of tests are welcome.

- **`allowClientBroadcast` registrations are matched against incoming messages with a linear scan.** Fine for a modest number of registered broadcast targets (the common case — a handful of interactable objects, settings panels, etc.); if your game registers broadcast permissions per-item across a large, dynamic set (e.g. per-item in a big inventory), that scan will show up in a profiler before anything else here does.

## License

MIT — see [LICENSE](LICENSE).
