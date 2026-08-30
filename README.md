# GameState

[![Wally](https://img.shields.io/badge/wally-your--scope%2Fgamestate-red)](https://wally.run/package/your-scope/gamestate)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A single source of truth for your game's state, shared between server and client, with built-in replication and safe client-to-server writes.

## Why this exists

Most Roblox games end up with state scattered across a dozen different systems — some in `DataStore`, some in loose tables, some replicated by hand through `RemoteEvent`s, some only living on the client. Every new feature means wiring up another remote, another `WaitForChild`, another place bugs can hide.

`GameState` collapses all of that into one nested structure you read and write like a plain Lua table. You don't design a schema up front — you just start reading and writing paths, and the structure builds itself as you go, replicating to clients and accepting safe writes back automatically:

```lua
GameState.Players[player.UserId].Coins(100)
print(GameState.Players[player.UserId].Coins()) --> 100
```

## Install

**Wally**

Add it to your `wally.toml`:

```toml
[dependencies]
GameState = "your-scope/gamestate@0.1.0"
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

Players.PlayerAdded:Connect(function(player)
    -- Set up their state
    GameState.Players[player.UserId].Coins(0)
    GameState.Players[player.UserId].Inventory.Items({})

    -- Replicate their own data to them
    GameState.Players[player.UserId].addSync(player)

    -- Let them spend coins from their own client, but only if they can afford it
    GameState.Players[player.UserId].Coins.allowClientBroadcast(player, function(newAmount)
        return typeof(newAmount) == "number" and newAmount >= 0
    end)
end)
```

**Client** (in a LocalScript, after requiring the same module):

```lua
local GameState = require(path.to.GameState)
local myUserId = Players.LocalPlayer.UserId

print(GameState.Players[myUserId].Coins())  -- reads whatever the server has synced so far

GameState.Players[myUserId].Coins.Changed(function(old, new)
    print("Coins changed from", old, "to", new)
end)
```

The module figures out on its own whether it's running on the server or the client and gives you the right version — you always just `require` the same thing.

## The mental model

Every point in the tree — `GameState`, `GameState.Players`, `GameState.Players[someId].Coins` — is a **node**. A node is called like a function to read or write it:

```lua
node()          -- read: returns the current value (nil if it was never set)
node(100)       -- write: sets the value to 100
node(nil)       -- write: explicitly clears it
node(function(old) return old + 1 end)  -- write: update based on the current value
```

Indexing into a node with `.` or `[]` gets you the child node at that key, creating it on the spot if it doesn't exist yet:

```lua
GameState.Players[player.UserId].Inventory.Items[1]("Sword")
```

You never "declare" `Players`, then `[userId]`, then `Inventory`, then `Items` — you just write to the full path and every level along the way gets created automatically.

Reading a node that holds a table gives you back a **plain Lua table snapshot**, not a live reference. Changing that table doesn't change what's stored — write it back (or use `Merge`/`Insert`/`RemoveValue`/`RemoveIndex`, see below) if you want the change to stick:

```lua
local items = GameState.Players[player.UserId].Inventory.Items()
table.insert(items, "Shield")   -- this does nothing to the actual stored state
GameState.Players[player.UserId].Inventory.Items(items)  -- this is what actually saves it
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
local disconnect = GameState.Players[userId].Coins.Changed(function(old, new) end)
disconnect()
```

- **`node.Changed(callback)`** — fires whenever this node's value changes at all, including changes to anything nested under it. `callback(old, new)`.
- **`node.KeyChanged(callback)`** — fires when a *direct* child of this node is added, removed, or changed. `callback(key, old, new)`. Doesn't fire for grandchildren — subscribe at the level you actually care about.
- **`node.ChildAdded(callback)`** — fires only when a direct child goes from not existing to existing. `callback(key, newValue)`.
- **`node.ChildRemoved(callback)`** — fires only when a direct child goes from existing to being cleared. `callback(key, lastValue)`.

**Timing to know about:** these callbacks fire *before* the write is actually applied internally. The `old`/`new` values you're given are correct, but if your callback ignores those and reads the node again itself (`GameState.Players[userId].Coins()` from inside that same `Coins.Changed` callback), you'll get the *old* value, not the one being written. Always use the arguments the callback hands you.

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
- **`node.disallowClientBroadcast(player)`** — revokes that permission for a player who's still connected. Same note as `removeSync` — not needed for players leaving.

### Client-only: sending writes to the server

- **`node.broadcastToServer()`** — sends this node's *current* value to the server for consideration. Write locally first so your own client updates immediately, then call this to ask the server to accept the same change:

  ```lua
  GameState.Players[myUserId].Coins.Update(function(old) return old - 10 end)
  GameState.Players[myUserId].Coins.broadcastToServer()
  ```

  This only does anything if the server called `allowClientBroadcast` for this exact path and player, and only takes effect if `validateData` accepts it — otherwise the server just quietly discards it. It also doesn't apply instantly: it's queued and sent roughly once per frame, not the moment you call it.

## Things to be careful of

- **`validateData` isn't optional in spirit, even though it's optional in the API.** Skipping it means that player can write *anything* correctly-shaped to that path, no restrictions at all. You'll get a warning in the output every time you register a broadcast target without one — treat that warning as a checklist item, not noise to ignore.

- **When a player leaves, you don't need to clean up their sync or broadcast registrations yourself — that's automatic.** Anything set up through `addSync` or `allowClientBroadcast` for that player gets torn down the moment they disconnect. You only need to call `removeSync`/`disallowClientBroadcast` yourself if you want to revoke access from someone who's *still connected*.

  This automatic cleanup is specifically about sync/broadcast *registrations*. It doesn't mean a player's actual data disappears — that's a separate decision you make in your own game logic (e.g. writing `nil` to clear their state, or leaving it in place if you want it to persist for when they rejoin).

- **Reading inside a `Changed`/`KeyChanged` callback can give you stale data — use the arguments instead.** Covered above, but easy to trip on: the callback fires before the internal write completes.

- **A node only ever holds *one* kind of shape at a time — array or dict, not both — and switching shapes on the fly is a common source of confusing bugs.** If a node currently holds an array and you write a dict-shaped table to it (or vice versa), that's a normal write and it'll happily overwrite it — but `Insert`/`RemoveValue`/`RemoveIndex`/`Merge` are shape-specific and will throw if you call the wrong one for what's currently there.

- **Reads return copies, not references.** Grabbing a table with `node()` and mutating it in place does nothing to the stored state — see "The mental model" above.

- **There's a rate limit and a payload size/depth limit on client broadcasts, by design.** If a client's writes seem to be silently getting dropped, check the server output — rejected broadcasts always log a warning explaining why (rate-limited, oversized, failed validation, etc.), they don't fail silently without a trace.

- **Don't call `broadcastToServer()` in a tight, unthrottled loop.** Nothing stops you locally, and it won't break anything (the server's own limits catch the excess), but it's still wasted client-side memory and network traffic for no benefit — batch your changes and broadcast once.

## Status

Fixed and verified through real Roblox Studio testing:
- A malformed client broadcast permanently breaking server-side sync/broadcast processing.
- Payload size/depth limits and a token-bucket rate limiter on client broadcasts.
- A memory leak from weak-table/closure interaction in Luau.
- A node auto-detach race that could silently break `addSync`/`allowClientBroadcast` registrations.
- Bugs in `Insert`/`RemoveValue`/`RemoveIndex`/`Merge`.

Explicitly still open:
- `DetachedChildren`'s weak-value bucket is reasoned-through-safe but not empirically stress-tested the way other weak tables were.
- No test yet for a player disconnecting mid-broadcast/mid-sync.
- Rate-limiter and payload-limit constants are placeholder values, not derived from real traffic — tune them for your game.

Issues and PRs welcome.

## License

MIT — see [LICENSE](LICENSE).
