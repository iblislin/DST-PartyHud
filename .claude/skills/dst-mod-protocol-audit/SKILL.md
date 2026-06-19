---
name: dst-mod-protocol-audit
description: Wire-protocol / data-channel design review for Don't Starve Together (DST) mods. Use this BEFORE adding or changing how a mod moves data between server and clients or across shards — a codec/serialization format, a netvar blob, a shard ModRPC, a net_string carrier — or when reviewing such a design or spec. It catches the design-level mistakes that are expensive to undo once shipped: adding new wire data for something already replicated on an existing channel (GetClientTable, player entity, existing netvars); folding STATIC data (identity/config) into a per-tick blob instead of delivering it event-driven; breaking backward/forward compatibility or a Master<->Caves rolling update; overflowing a netvar's range/type; and crashing on a malformed payload. Trigger whenever the user designs/changes/reviews a mod's networking, serialization, cross-shard data flow, adds or reorders a field in a wire format, bumps a protocol version, or asks "is this protocol change safe / backward compatible / efficient / event-driven" — even if they never say "protocol audit".
---

# DST Mod Protocol-Design Audit

## Why this exists

The bugs that hurt most in a mod's networking layer are **design** bugs, not typos: a field added to a
per-tick blob that re-transmits forever, a version bump that breaks the un-updated shard during a
rolling restart, a `net_byte` that silently wraps a value > 255, a decoder that throws on a truncated
payload and takes the shard down. None of these are caught by `luacheck`, by `busted` round-trip tests
(which only prove the encoder and decoder agree *with each other*), or by a no-player load smoke. They
are caught by reasoning about the protocol's **shape, lifecycle, and compatibility** before it ships —
which is what this audit does.

This is a **design** review. Pair it with `dst-mod-crash-audit` (the runtime-crash lens — a protocol's
decode path is a prime naked-callback crash site) and `dst-badge-visual-audit` (HUD parity). The cheap
first gate (`luacheck`) and the real last gate (a **2-shard, multi-player in-game test of the actual
wire round-trip**) still apply — this audit sits between them.

Load `references/protocol-design-gotchas.md` before auditing — it carries the DST networking facts
(what each channel already replicates, netvar ranges, shard-RPC semantics, the modmain-sandbox trap)
and the worked PartyHud examples this skill generalizes from.

## Before you start — get ground truth

1. **The protocol under review** — the codec / RPC / netvar / carrier code (or the design doc), AND
   *what data it carries, how often, and in which direction* (server→client, client→server, shard→shard).
2. **The existing channels** — list what the mod (and the game) ALREADY replicate, because the most
   valuable finding is usually "you don't need this wire change at all." Read the mod's current
   networking + check the game source for what rides for free (see dimension 1).
3. **The game's networking source** to verify every claim against (commonly
   `~/code/dst/dst-scripts/scripts/`): `networking.lua` (GetClientTable contents, player colours),
   `netvars.lua` (the exact net_* types + ranges), `networkclientrpc.lua` + `shardnetworking.lua`
   (RPC/shard-RPC semantics), `constants.lua` (USERFLAGS, SHARDID). Do NOT trust wikis/memory.

## Method: fan out by dimension, then verify

Same shape as `dst-mod-crash-audit`: the dimensions are largely independent, so breadth beats a single
pass.

1. **Dispatch READ-ONLY subagents to verify the load-bearing game-source claims, in parallel.** These are
   often FEWER than 6 — one fact (e.g. what `GetClientTable()` already carries) serves several dimensions,
   so fanning out strictly one-per-dimension duplicates the same lookup. Spawn by *verification target*
   (what is already on GetClientTable / can a client read field X / netvar ranges / decode-path safety),
   give each the protocol code/design + the game-source path, then walk all 6 dimensions yourself in
   synthesis. Each subagent reports every **finding** (severity: blocker / waste / compat-risk /
   fragility / none; the exact scenario; the game-source or mod evidence; a concrete fix) AND, for each
   checked item found safe, a one-line note with the reason — so coverage is visible, not just problems.
2. **Audit the auditors.** Re-read the cited evidence yourself; a confident "this rides GetClientTable
   for free" or "this decode is malformed-safe" is exactly the kind of load-bearing claim that is
   sometimes wrong. Verify against the game source.
3. **Synthesize one report** (template below): blockers first, then waste/cleanliness, then a "verified
   safe" list, then a verdict.

If subagents aren't available, walk the 6 dimensions in sequence — same checklist, you lose the
parallelism and the independent second opinion.

## The 6 dimensions (the checklist)

Pair each with the matching section of `references/protocol-design-gotchas.md`.

1. **Does this data need a new channel at all?** The highest-leverage question. Before designing any new
   wire format, check whether the data is ALREADY replicated on a channel the client can read:
   `TheNet:GetClientTable()` is cluster-wide and carries `{userid, name, prefab, colour, base_skin,
   userflags, ...}` for every player on both shards; the player entity exposes public fields client-side
   (`prefab`, `playercolour`); existing netvars may already carry it. **Adding wire data for something
   already replicated is pure waste and new surface area.** (PartyHud v2026.11: cross-shard avatars
   needed zero new wire — `GetClientTable` already had `prefab`/`colour`/`userflags` — instead of the
   codec-v3 field first proposed.) Findings here often delete the rest of the protocol change.

2. **Static vs dynamic → event-driven vs polling.** Classify every field by how often its VALUE changes.
   **Static / identity / config** (character prefab, player colour, a config choice — changes only on
   discrete events: join, character-select, ghost/were transition, skin change, migration) must be
   delivered **event-driven** (once on join + on-change), NOT folded into a per-tick / high-frequency
   blob — there it re-transmits and re-encodes forever for no reason. **Dynamic** (HP, position, a
   countdown) is the only thing that belongs in a periodic broadcast, paired with reconcile/TTL. Red
   flag: a static field sharing a record with a field that changes every tick (the dynamic field drags
   the static one along on every transmit). Prefer "send identity on the change event" or "read it from
   an already-on-change channel" (see dim 1) over "send everything every tick."

3. **Backward / forward compatibility + rolling update.** A versioned wire format must survive peers on
   different mod versions — which is the NORM during a Workshop update or a Master/Caves rolling restart
   (one shard updated, the other not, for minutes). Check: a **version field** is present and checked;
   the decoder handles **older** versions (sensible defaults for fields that didn't exist) AND
   **unknown/newer** versions **gracefully (ignore/skip, never crash)**; changes are **append-only** (new
   fields at the end — never reorder or repurpose existing field positions, which silently misreads on
   an old peer); the **version is bumped on ANY wire change**. Ask explicitly: "what does last release's
   shard do when it receives this new payload, and vice versa?"

4. **Wire cost + netvar range/type fit.** `payload size × frequency` — is the cost justified, especially
   for anything in a periodic broadcast? Every `net_*` declaration vs every `:set()`: can the value
   exceed the netvar's range or be the wrong type? (`net_byte` 0..255 wraps a value >255; a float into
   `net_byte`/`net_ushortint` truncates; a negative into an unsigned wraps — the historical WX-78
   400-HP-into-net_byte class.) For compact encodings, weigh **compactness vs robustness**: an integer
   index into a list is smaller but **breaks for mod content** whose list position is unstable across
   clients (PartyHud: prefer the prefab STRING over a char-id index). Delimited records (`:` / `|`):
   confirm no field value can contain the separator.

5. **Malformed / partial / empty-payload robustness.** A decoder is an attack surface for corrupt or
   cross-version data. It must **never throw** on a bad payload — guard the decode and **log-and-drop**
   (the shard-RPC handler and the broadcast decode are naked callbacks; an uncaught throw there halts the
   shard — see `dst-mod-crash-audit` + the crash guard). Check: field-count validation before indexing;
   `tonumber`/type checks on decoded fields (never trust the wire); **empty-not-nil** (`GetClientTable()`
   can return a non-nil EMPTY table transiently — guard `#t > 0`); partial/truncated record handling;
   and the modmain-sandbox trap if any codec/handler code runs in `modmain.lua` (bare `tonumber`/`pcall`
   are nil there — use `GLOBAL.*`).

6. **Versioning hygiene + single source of truth + tests.** The codec is the **single source of truth**
   for the wire format — encode and decode live together and stay symmetric; field order + meaning are
   documented at the codec; the protocol-version constant is the one knob. Tests: a **busted round-trip**
   (encode→decode is identity) AND **cross-version decode** tests (a v(N-1) payload decodes with the new
   decoder; an unknown-version payload is ignored, not crashed) — round-trip alone only proves the codec
   agrees with itself, not that it's compatible. Pure codec logic should be an engine-free module so
   these tests need no game runtime.

## Output: the audit report

```
# Protocol-design audit — <protocol/change name> @ <version/commit>

## Blockers (ship-stoppers), verified
- [<dimension>] <what breaks, in which scenario (rolling update / wrap / crash / already-free)> — <fix>. Evidence: <source ref>.

## Waste / cleanliness (cost, redundancy, per-tick static data)
- ...

## Verified safe (so coverage is visible)
- <dimension>: <what was checked and why it's sound>

## Verdict
<Is the protocol change sound + necessary? Could it be avoided (dim 1)? Is it rolling-update-safe and
malformed-safe? What runtime test still has to happen (2-shard in-game wire round-trip)?>
```

Severity guide: **blocker** = will break compatibility, wrap a value, crash a decode, or is entirely
unnecessary (already replicated); **waste** = works but pays cost it needn't (per-tick static data,
oversized encoding); **fragility** = survives the happy path but not a malformed/cross-version one;
**none** = sound. Be honest about probability and about the cheapest fix (often: don't add the channel).

## After the audit

State what this does and does NOT cover. It does not replace `luacheck`, `dst-mod-crash-audit` on the
decode path, or the real gate: a **2-shard, multi-player in-game test of the actual wire round-trip**
(join/leave/migrate/ghost while the protocol is live) — and during a version change, a test with **mixed
mod versions** across the two shards if you can stage it. When the protocol relies on a non-obvious
invariant (a field is static, a channel is cluster-wide, a value fits a range), suggest recording it as
an inline comment at the codec so the next maintainer (or a future field addition) is flagged.
