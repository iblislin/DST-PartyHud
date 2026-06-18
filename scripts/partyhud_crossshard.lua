-- partyhud_crossshard.lua
--
-- v2026.8 cross-shard player status store (Tier-0 pure-logic layer).
--
-- Holds the status records of players that belong to OTHER shards, as broadcast via the
-- cross-shard RPC.  The server-side wiring (RPC handler, game-clock reads, periodic expire,
-- TheNet:GetClientTable reconciliation) is a SEPARATE higher-level module and is NOT in scope
-- here.  This module is intentionally engine-free (no GLOBAL / TheWorld / os.time) so it can
-- be fully unit-tested under busted on a plain LuaJIT with nothing mocked.
--
-- Callers pass the current monotonic timestamp as the `now` argument.  Any numeric origin and
-- unit (seconds since epoch, game ticks, ...) is fine as long as it's consistent -- the store
-- only ever computes differences (now - last_update).
--
-- Internal representation
-- -----------------------
-- store._data[userid] = { <all record fields>, _last_update = <now at last upsert> }
--
-- The underscore-prefixed field is the ONLY internal bookkeeping the store adds.  active()
-- strips it before returning records to callers (the renderer must not see it).
--
-- Lua 5.1 nil-in-table note: assigning a table field to nil makes the key absent -- pairs()
-- will never visit it.  The store avoids relying on nil-presence for bookkeeping; it uses an
-- explicit numeric timestamp instead.

local M = {}

-- new() -> store
-- Returns a fresh, empty store.  Multiple independent stores can coexist (no module-level
-- mutable state is used).
function M.new()
  return { _data = {} }
end

-- upsert(store, records, now)
-- Merges an array of decoded status records into the store.  Last-write-wins per userid:
-- a later upsert for the same userid fully replaces the previous entry and refreshes its
-- timestamp.  `records` may be nil or an empty table -- both are treated as no-ops.
-- `now` must be a number (the caller's current clock value).
function M.upsert(store, records, now)
  if not records then
    return
  end
  for _, rec in ipairs(records) do
    -- Shallow-copy the record so the store owns its own data (caller may reuse theirs).
    local entry = {}
    for k, v in pairs(rec) do
      entry[k] = v
    end
    entry._last_update = now
    store._data[rec.userid] = entry
  end
end

-- expire(store, now, ttl) -> removed_count
-- Removes entries that are strictly older than `ttl` time units.
--
-- Boundary contract (document precisely so callers can set ttl without off-by-one surprises):
--   age  = now - entry._last_update
--   age > ttl  --> removed    (strictly greater: stale)
--   age == ttl --> kept       (exactly at the edge: still considered fresh)
--   age < ttl  --> kept       (clearly fresh)
--
-- Returns the number of entries removed.
function M.expire(store, now, ttl)
  local removed = 0
  local to_remove = {}
  for userid, entry in pairs(store._data) do
    if (now - entry._last_update) > ttl then
      to_remove[#to_remove + 1] = userid
    end
  end
  for _, userid in ipairs(to_remove) do
    store._data[userid] = nil
    removed = removed + 1
  end
  return removed
end

-- active(store) -> array of records
-- Returns a snapshot of all currently stored records, sorted by userid (deterministic order
-- for stable rendering / diffing).  Each returned record is a CLEAN copy of the stored
-- entry with the internal `_last_update` field stripped -- the renderer must not rely on or
-- accidentally display it.
function M.active(store)
  -- Collect all userids first so we can sort them.
  local userids = {}
  for userid in pairs(store._data) do
    userids[#userids + 1] = userid
  end
  table.sort(userids)

  local out = {}
  for _, userid in ipairs(userids) do
    local entry = store._data[userid]
    local rec = {}
    for k, v in pairs(entry) do
      -- Strip the single internal bookkeeping field.
      if k ~= "_last_update" then
        rec[k] = v
      end
    end
    out[#out + 1] = rec
  end
  return out
end

-- reconcile(store, live_userids) -> removed_count
-- Drops any stored userid NOT present in `live_userids`.
--
-- `live_userids` may be supplied in two forms (the caller picks whichever is convenient):
--   * ARRAY  -- e.g. { "KU_a", "KU_b" }        (ipairs-iterable)
--   * SET    -- e.g. { ["KU_a"]=true, ["KU_b"]=true }  (key-lookup table)
-- Both are handled by building a set on the fly when needed (see below).
-- An empty or nil `live_userids` results in ALL entries being removed.
--
-- Returns the number of entries removed.
function M.reconcile(store, live_userids)
  -- Normalise to a set (key -> true) for O(1) membership tests.
  local live_set = {}
  if live_userids then
    for k, v in pairs(live_userids) do
      if type(k) == "number" then
        -- Array form: values are userids (must be strings; non-string values
        -- are silently ignored to guard against accidental numeric arrays).
        if type(v) == "string" then
          live_set[v] = true
        end
      else
        -- Set form: keys are userids.
        live_set[k] = true
      end
    end
  end

  local removed = 0
  local to_remove = {}
  for userid in pairs(store._data) do
    if not live_set[userid] then
      to_remove[#to_remove + 1] = userid
    end
  end
  for _, userid in ipairs(to_remove) do
    store._data[userid] = nil
    removed = removed + 1
  end
  return removed
end

-- v2026.11 (extracted for test): merge this shard's own player records with the foreign (other-shard)
-- records into one userid-deduped array. LOCAL wins -- a player briefly present in both sets (mid
-- shard-migration) appears once, as the local copy. Skips nil/"" userids in the local set and nil
-- userids in the foreign set (matching the publish-time guards).
function M.merge_local_foreign(local_records, foreign_records)
  local merged, seen = {}, {}
  for _, r in ipairs(local_records or {}) do
    if r.userid ~= nil and r.userid ~= "" and not seen[r.userid] then
      seen[r.userid] = true
      merged[#merged + 1] = r
    end
  end
  for _, r in ipairs(foreign_records or {}) do
    if r.userid ~= nil and not seen[r.userid] then
      seen[r.userid] = true
      merged[#merged + 1] = r
    end
  end
  return merged
end

-- v2026.11 (extracted for test): this client's own shard id, read from ITS OWN record in the broadcast
-- blob (the server stamps every local player -- incl. ThePlayer -- with this shard's origin). Returns
-- the origin number, or nil if my_userid is nil or no matching record with an origin is present yet.
-- (TheShard:GetShardId() is unreliable on a pure client -- see the v2026.8/.9 notes -- so we derive it.)
function M.my_shard_from_records(records, my_userid)
  if my_userid == nil then
    return nil
  end
  for _, r in ipairs(records or {}) do
    if r.userid == my_userid and r.origin ~= nil then
      return r.origin
    end
  end
  return nil
end

-- v2026.11 (extracted for test): is a foreign record on the SAME shard as this client? True only when
-- both the record's origin and my_shard are known and equal -> "far" (same-shard out-of-view);
-- otherwise (nil origin from a v1 peer, or unknown my_shard) treat as cross-shard ("Caves"/"Surface").
function M.is_same_shard(rec_origin, my_shard)
  return (my_shard ~= nil and rec_origin ~= nil and rec_origin == my_shard)
end

return M
