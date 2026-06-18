-- spec/crossshard_spec.lua
--
-- busted unit tests for the v2026.8 cross-shard status store (Tier-0 pure-logic layer).
-- Runs in CI via `busted spec/` and locally via spec/run_local.lua on plain LuaJIT.

local store = require("partyhud_crossshard")

-- Helper: build a minimal but valid status record (mirrors the codec's field set).
local function rec(userid, hp_cur)
    return {
        userid         = userid,
        hp_cur         = hp_cur or 100,
        hp_max         = 150,
        hp_penalty     = 0,
        hunger         = 80,
        sanity_cur     = 120,
        sanity_max     = 200,
        sanity_penalty = 0,
        flags          = 0,
    }
end

-- Helper: build an array of N records with distinct userids.
local function sample(n)
    local recs = {}
    for i = 1, n do
        recs[i] = rec("KU_user" .. i, 100 + i)
    end
    return recs
end

-- Helper: check that a record returned by active() carries no internal bookkeeping field.
local function has_no_internal(r)
    return r._last_update == nil
end

describe("partyhud crossshard store", function()

    -- ------------------------------------------------------------------
    describe("new", function()
        it("returns an independent empty store each time", function()
            local s1 = store.new()
            local s2 = store.new()
            store.upsert(s1, sample(1), 1000)
            -- s2 must be unaffected
            assert.are.equal(0, #store.active(s2))
        end)
    end)

    -- ------------------------------------------------------------------
    describe("upsert", function()
        it("stores a single record", function()
            local s = store.new()
            store.upsert(s, { rec("KU_a") }, 1000)
            local got = store.active(s)
            assert.are.equal(1, #got)
            assert.are.equal("KU_a", got[1].userid)
        end)

        it("stores multiple records", function()
            local s = store.new()
            store.upsert(s, sample(4), 1000)
            assert.are.equal(4, #store.active(s))
        end)

        it("nil records is a no-op (does not throw)", function()
            local s = store.new()
            store.upsert(s, nil, 1000)
            assert.are.equal(0, #store.active(s))
        end)

        it("empty records table is a no-op", function()
            local s = store.new()
            store.upsert(s, {}, 1000)
            assert.are.equal(0, #store.active(s))
        end)

        it("overwrites an existing userid (last-write-wins)", function()
            local s = store.new()
            store.upsert(s, { rec("KU_a", 100) }, 1000)
            store.upsert(s, { rec("KU_a", 200) }, 2000) -- newer upsert
            local got = store.active(s)
            assert.are.equal(1, #got)         -- only one entry
            assert.are.equal(200, got[1].hp_cur) -- newer value wins
        end)

        it("updates the timestamp on overwrite", function()
            -- Verify indirectly: after overwriting with now=2000, the entry's age
            -- at now=2010 is 10, so expire(ttl=9) should remove it while a fresh
            -- entry (never overwritten, last_update=2000) with the same gap would
            -- also be removed.  The key test: ttl=10 keeps it (age == ttl), ttl=9 removes.
            local s = store.new()
            store.upsert(s, { rec("KU_a", 100) }, 1000) -- first write at t=1000
            store.upsert(s, { rec("KU_a", 200) }, 2000) -- overwrite at t=2000
            -- At now=2010, age=10.  ttl=10 keeps (age==ttl boundary).
            local n = store.expire(s, 2010, 10)
            assert.are.equal(0, n)
            -- At now=2011, age=11 > ttl=10 -> removed.
            n = store.expire(s, 2011, 10)
            assert.are.equal(1, n)
        end)

        it("preserves all record fields intact", function()
            local s = store.new()
            local r = rec("KU_full", 123)
            r.hp_max         = 400
            r.hp_penalty     = 25
            r.hunger         = 75
            r.sanity_cur     = 90
            r.sanity_max     = 200
            r.sanity_penalty = 10
            r.flags          = 5
            store.upsert(s, { r }, 1000)
            local got = store.active(s)
            assert.are.equal(1, #got)
            local g = got[1]
            assert.are.equal("KU_full",   g.userid)
            assert.are.equal(123,          g.hp_cur)
            assert.are.equal(400,          g.hp_max)
            assert.are.equal(25,           g.hp_penalty)
            assert.are.equal(75,           g.hunger)
            assert.are.equal(90,           g.sanity_cur)
            assert.are.equal(200,          g.sanity_max)
            assert.are.equal(10,           g.sanity_penalty)
            assert.are.equal(5,            g.flags)
        end)

        it("store is unaffected by caller mutating the record after upsert", function()
            local s = store.new()
            local r = rec("KU_a", 100)
            store.upsert(s, { r }, 1000)
            r.hp_cur = 999  -- mutate caller's original after upsert
            assert.are.equal(100, store.active(s)[1].hp_cur)
        end)
    end)

    -- ------------------------------------------------------------------
    describe("expire", function()
        it("removes entries strictly older than ttl (age > ttl)", function()
            local s = store.new()
            store.upsert(s, { rec("KU_old") }, 1000)
            -- age at now=1100 is 100, ttl=99 -> 100 > 99 -> removed
            local n = store.expire(s, 1100, 99)
            assert.are.equal(1, n)
            assert.are.equal(0, #store.active(s))
        end)

        it("keeps entries whose age exactly equals ttl (boundary: age == ttl kept)", function()
            local s = store.new()
            store.upsert(s, { rec("KU_edge") }, 1000)
            -- age at now=1100 is 100, ttl=100 -> 100 == 100 -> kept
            local n = store.expire(s, 1100, 100)
            assert.are.equal(0, n)
            assert.are.equal(1, #store.active(s))
        end)

        it("keeps entries that are clearly fresh (age < ttl)", function()
            local s = store.new()
            store.upsert(s, { rec("KU_fresh") }, 1000)
            -- age at now=1050 is 50, ttl=100 -> 50 < 100 -> kept
            local n = store.expire(s, 1050, 100)
            assert.are.equal(0, n)
            assert.are.equal(1, #store.active(s))
        end)

        it("selectively removes only stale entries among a mixed set", function()
            local s = store.new()
            store.upsert(s, { rec("KU_stale") },  1000)  -- old
            store.upsert(s, { rec("KU_fresh") },  1090)  -- recent
            -- at now=1100, ttl=50: stale age=100>50 removed; fresh age=10<=50 kept
            local n = store.expire(s, 1100, 50)
            assert.are.equal(1, n)
            local got = store.active(s)
            assert.are.equal(1, #got)
            assert.are.equal("KU_fresh", got[1].userid)
        end)

        it("returns 0 on an empty store", function()
            local s = store.new()
            assert.are.equal(0, store.expire(s, 9999, 10))
        end)
    end)

    -- ------------------------------------------------------------------
    describe("active", function()
        it("returns an empty array for an empty store", function()
            local s = store.new()
            local got = store.active(s)
            assert.are.equal(0, #got)
        end)

        it("returns records sorted by userid (deterministic order)", function()
            local s = store.new()
            -- Insert in reverse-lexicographic order to confirm sorting.
            store.upsert(s, { rec("KU_zzz") }, 1000)
            store.upsert(s, { rec("KU_aaa") }, 1000)
            store.upsert(s, { rec("KU_mmm") }, 1000)
            local got = store.active(s)
            assert.are.equal(3, #got)
            assert.are.equal("KU_aaa", got[1].userid)
            assert.are.equal("KU_mmm", got[2].userid)
            assert.are.equal("KU_zzz", got[3].userid)
        end)

        it("does not leak the internal _last_update field", function()
            local s = store.new()
            store.upsert(s, sample(3), 1000)
            for _, r in ipairs(store.active(s)) do
                assert.is_true(has_no_internal(r))
            end
        end)

        it("returns independent copies (mutating the result does not affect the store)", function()
            local s = store.new()
            store.upsert(s, { rec("KU_a", 100) }, 1000)
            local got = store.active(s)
            got[1].hp_cur = 999  -- mutate the returned snapshot
            -- The store must be unchanged.
            local got2 = store.active(s)
            assert.are.equal(100, got2[1].hp_cur)
        end)
    end)

    -- ------------------------------------------------------------------
    describe("reconcile", function()
        it("keeps entries present in the live roster (array form)", function()
            local s = store.new()
            store.upsert(s, sample(3), 1000)  -- KU_user1, KU_user2, KU_user3
            local n = store.reconcile(s, { "KU_user1", "KU_user2", "KU_user3" })
            assert.are.equal(0, n)
            assert.are.equal(3, #store.active(s))
        end)

        it("drops entries absent from the live roster (array form)", function()
            local s = store.new()
            store.upsert(s, sample(3), 1000)
            -- only KU_user1 is still live; KU_user2 and KU_user3 have left
            local n = store.reconcile(s, { "KU_user1" })
            assert.are.equal(2, n)
            local got = store.active(s)
            assert.are.equal(1, #got)
            assert.are.equal("KU_user1", got[1].userid)
        end)

        it("keeps entries present in the live roster (set form)", function()
            local s = store.new()
            store.upsert(s, sample(2), 1000)
            local n = store.reconcile(s, { ["KU_user1"] = true, ["KU_user2"] = true })
            assert.are.equal(0, n)
            assert.are.equal(2, #store.active(s))
        end)

        it("drops entries absent from the live roster (set form)", function()
            local s = store.new()
            store.upsert(s, sample(3), 1000)
            local n = store.reconcile(s, { ["KU_user1"] = true })
            assert.are.equal(2, n)
        end)

        it("drops ALL entries when live roster is empty table", function()
            local s = store.new()
            store.upsert(s, sample(4), 1000)
            local n = store.reconcile(s, {})
            assert.are.equal(4, n)
            assert.are.equal(0, #store.active(s))
        end)

        it("drops ALL entries when live roster is nil", function()
            local s = store.new()
            store.upsert(s, sample(4), 1000)
            local n = store.reconcile(s, nil)
            assert.are.equal(4, n)
            assert.are.equal(0, #store.active(s))
        end)

        it("returns 0 on an already-empty store", function()
            local s = store.new()
            assert.are.equal(0, store.reconcile(s, { "KU_nobody" }))
        end)
    end)

    -- ------------------------------------------------------------------
    describe("combined workflows", function()
        it("upsert -> expire -> active round-trip", function()
            local s = store.new()
            store.upsert(s, { rec("KU_a") }, 1000)
            store.upsert(s, { rec("KU_b") }, 1080)
            -- At now=1101, ttl=100: KU_a age=101>100 removed; KU_b age=21<=100 kept
            store.expire(s, 1101, 100)
            local got = store.active(s)
            assert.are.equal(1, #got)
            assert.are.equal("KU_b", got[1].userid)
            assert.is_true(has_no_internal(got[1]))
        end)

        it("upsert -> reconcile -> active round-trip", function()
            local s = store.new()
            store.upsert(s, sample(5), 1000)
            store.reconcile(s, { "KU_user2", "KU_user4" })
            local got = store.active(s)
            assert.are.equal(2, #got)
            -- sorted: KU_user2 < KU_user4
            assert.are.equal("KU_user2", got[1].userid)
            assert.are.equal("KU_user4", got[2].userid)
        end)
    end)

    -- ------------------------------------------------------------------
    describe("merge_local_foreign", function()
        it("local-only set passes through unchanged", function()
            local got = store.merge_local_foreign(
                { { userid = "A", hp = 1 }, { userid = "B", hp = 2 } }, {})
            assert.are.same(
                { { userid = "A", hp = 1 }, { userid = "B", hp = 2 } }, got)
        end)

        it("foreign-only set passes through unchanged", function()
            local got = store.merge_local_foreign(
                {}, { { userid = "X", hp = 7 }, { userid = "Y", hp = 8 } })
            assert.are.same(
                { { userid = "X", hp = 7 }, { userid = "Y", hp = 8 } }, got)
        end)

        it("a userid in BOTH keeps the LOCAL copy", function()
            local local_recs   = { { userid = "DUP", hp = 111 } }
            local foreign_recs = { { userid = "DUP", hp = 222 } }
            local got = store.merge_local_foreign(local_recs, foreign_recs)
            assert.are.equal(1, #got)
            assert.are.equal(111, got[1].hp) -- local hp survived, not the foreign 222
        end)

        it("dedups within the local set (same userid twice -> once)", function()
            local got = store.merge_local_foreign(
                { { userid = "A", hp = 1 }, { userid = "A", hp = 9 } }, {})
            assert.are.equal(1, #got)
            assert.are.equal(1, got[1].hp) -- first occurrence wins
        end)

        it("skips a nil userid in the local set", function()
            local got = store.merge_local_foreign(
                { { userid = nil, hp = 1 }, { userid = "B", hp = 2 } }, {})
            assert.are.equal(1, #got)
            assert.are.equal("B", got[1].userid)
        end)

        it('skips an "" (empty-string) userid in the local set', function()
            local got = store.merge_local_foreign(
                { { userid = "", hp = 1 }, { userid = "B", hp = 2 } }, {})
            assert.are.equal(1, #got)
            assert.are.equal("B", got[1].userid)
        end)

        it("skips a nil userid in the foreign set", function()
            local got = store.merge_local_foreign(
                {}, { { userid = nil, hp = 1 }, { userid = "Y", hp = 2 } })
            assert.are.equal(1, #got)
            assert.are.equal("Y", got[1].userid)
        end)

        it("empty both -> {}", function()
            assert.are.same({}, store.merge_local_foreign({}, {}))
        end)

        it("nil both -> {}", function()
            assert.are.same({}, store.merge_local_foreign(nil, nil))
        end)

        it("ORDER is all locals (input order) then un-seen foreign", function()
            local local_recs = {
                { userid = "L1", hp = 1 },
                { userid = "L2", hp = 2 },
            }
            local foreign_recs = {
                { userid = "L1", hp = 99 }, -- already seen (local) -> dropped
                { userid = "F1", hp = 3 },
                { userid = "F2", hp = 4 },
            }
            local got = store.merge_local_foreign(local_recs, foreign_recs)
            assert.are.equal(4, #got)
            assert.are.equal("L1", got[1].userid)
            assert.are.equal("L2", got[2].userid)
            assert.are.equal("F1", got[3].userid)
            assert.are.equal("F2", got[4].userid)
            assert.are.equal(1, got[1].hp) -- L1 kept the local copy
        end)
    end)

    -- ------------------------------------------------------------------
    describe("my_shard_from_records", function()
        it("returns the origin of the record whose userid == my_userid", function()
            local recs = {
                { userid = "A", origin = 1 },
                { userid = "ME", origin = 2 },
                { userid = "B", origin = 3 },
            }
            assert.are.equal(2, store.my_shard_from_records(recs, "ME"))
        end)

        it("returns nil when my_userid is nil", function()
            local recs = { { userid = "ME", origin = 2 } }
            assert.is_nil(store.my_shard_from_records(recs, nil))
        end)

        it("returns nil when no record matches my_userid", function()
            local recs = { { userid = "A", origin = 1 }, { userid = "B", origin = 2 } }
            assert.is_nil(store.my_shard_from_records(recs, "ME"))
        end)

        it("returns nil when the matching record has origin == nil", function()
            local recs = { { userid = "ME", origin = nil } }
            assert.is_nil(store.my_shard_from_records(recs, "ME"))
        end)

        it("first matching record with an origin wins if duplicates", function()
            local recs = {
                { userid = "ME", origin = 5 },
                { userid = "ME", origin = 6 },
            }
            assert.are.equal(5, store.my_shard_from_records(recs, "ME"))
        end)

        it("works with a large numeric origin", function()
            local recs = { { userid = "ME", origin = 338108181 } }
            assert.are.equal(338108181, store.my_shard_from_records(recs, "ME"))
        end)

        it("nil/empty records -> nil", function()
            assert.is_nil(store.my_shard_from_records(nil, "ME"))
            assert.is_nil(store.my_shard_from_records({}, "ME"))
        end)
    end)

    -- ------------------------------------------------------------------
    describe("is_same_shard", function()
        it("(1, 1) -> true", function()
            assert.is_true(store.is_same_shard(1, 1))
        end)

        it("(2, 1) -> false", function()
            assert.is_false(store.is_same_shard(2, 1))
        end)

        it("(nil, 1) -> false", function()
            assert.is_false(store.is_same_shard(nil, 1))
        end)

        it("(1, nil) -> false", function()
            assert.is_false(store.is_same_shard(1, nil))
        end)

        it("(nil, nil) -> false", function()
            assert.is_false(store.is_same_shard(nil, nil))
        end)

        it("large equal numbers (338108181, 338108181) -> true", function()
            assert.is_true(store.is_same_shard(338108181, 338108181))
        end)
    end)

end)
