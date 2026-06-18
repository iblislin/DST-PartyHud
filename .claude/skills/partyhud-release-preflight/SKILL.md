---
name: partyhud-release-preflight
description: Shipping pre-flight checklist to run BEFORE tagging or publishing a new PartyHud release. Use this WHENEVER the user moves to ship / release / cut / roll out / tag / publish a new PartyHud version — phrasings like "ship v2026.X", "let's tag", "cut a release", "roll out a new release", "publish to Workshop", "push the new version", "release PartyHud", or any step toward creating a vYYYY.N tag — even if they never say "pre-flight" or "checklist". The #1 job is the production-accident guard: the release archive is built from an allowlist (release-manifest.txt), so a runtime-required Lua module left out of the allowlist ships a mod that fails to load in a live game. The checklist confirms the allowlist, runs the crash-safety audit + static gates, verifies the version bump, reminds about an in-engine load-smoke, THEN tags. Trigger on any release/ship/tag intent; under-triggering is the failure mode.
---

# PartyHud Release Pre-Flight

## Why this exists

The release archive is **not** "the whole repo". `.github/workflows/release.yml` builds it from an
**allowlist** — `release-manifest.txt`. Anything not on that allowlist never reaches the player.
So the worst-case shipping accident is: a new runtime-required Lua module is added, never listed in
the manifest, passes every static gate (luacheck/busted run on the source tree, not the archive),
gets tagged, ships — and the mod **fails to load in a live game** because `require` hits a file that
isn't in the zip. luacheck and busted cannot catch this; only the manifest gate can.

Run gates 1–5 in order before tagging. Each gate explains *why* so you can judge edge cases instead
of rubber-stamping. Stop and surface to the user on any hard failure.

## 0. Preconditions

- All intended changes are **committed** and the working tree is clean (`git status`). The archive is
  built from committed content at the tag, so uncommitted edits silently won't ship.
- You're on `master` (releases tag `master`).
- Decide the **new version number**. Tags are `vYYYY.N` (e.g. `v2026.10`); the next release is
  `v<YEAR>.<N+1>` past the latest tag. Find the latest with:
  `git tag --sort=-v:refname | head -1`

## 1. Manifest / allowlist guard — the production-accident guard

```bash
bash tools/check-manifest.sh   # run from the repo root
```

- Exit 0 = pass. The script prints `✓`/`✗` per HARD check and a final `RESULT:` line.
- `release-manifest.txt` is the **single source of truth** for shipped files: top-level files listed
  explicitly, plus the whole `scripts/` directory (so new `scripts/*.lua` are picked up automatically).
- **SOFT warnings do NOT fail the script but REQUIRE a human decision.** A `⚠ SOFT WARNING` block
  means a new unclassified top-level file appeared. For each one decide:
  - **It must ship** (a runtime module / asset) → add it to `release-manifest.txt`.
  - **It's dev/infra** (CI, tooling, tests, docs) → add it to the script's `known_exclude` set.
  Never leave a SOFT warning unresolved "because it didn't fail" — that's exactly the silent-omission
  path this gate exists to close.
- If a runtime module lives under `scripts/`, it's already covered by the directory entry; the danger
  is a new **top-level** runtime file, or a `require` pointing at a path no manifest entry covers.

## 2. Static gates

All three must be green. These run on the **source tree**, so they prove code correctness + style but
say nothing about what's in the archive (that's gate 1's job).

- **luacheck — 0 warnings / 0 errors.** Locally `luacheck .` (or the hub luacheck docker image).
  CI: `.github/workflows/luacheck.yml`.
- **busted — green.** CI runs real busted (`.github/workflows/busted.yml`). Locally there is no
  luarocks, so run the shim: `luajit spec/run_local.lua`.
- **StyLua — formatted (`stylua --check .` exits 0).** CI: `.github/workflows/stylua.yml` (a blocking
  check, pinned StyLua version). If it fails, run `stylua .` to auto-format then re-review the diff.
  Config: `.stylua.toml` (2-space, Lua 5.1).

## 3. Crash-safety audit

Invoke the repo skill **`.claude/skills/dst-mod-crash-audit/SKILL.md`** and audit the **diff since the
last release tag** (`git diff v<latest>..HEAD`). It catches the runtime crash classes luacheck cannot:
nil/wrong-`inst` access, shard-migration faults, ghost/death state, netvar range overflow, listener
lifecycle, Lua-semantics traps, client-vs-server context.

If the release changed any **badge / HUD / status-widget visuals**, also run
**`.claude/skills/dst-badge-visual-audit/SKILL.md`** for visual-parity bugs (wrong build/tint/scale,
draw order, fill direction, layout/wrap, collision with vanilla HUD widgets).

## 4. Version-bump check

Read `modinfo.lua` and confirm the version field. Current format (single line, double-quoted, no
leading `v`):

```lua
version="2026.10"
```

Verify all three line up:
- `modinfo.lua` `version=` equals the intended new version **without** the leading `v` (tag `v2026.11`
  ⇒ `version="2026.11"`).
- The intended version is **greater than** the latest shipped tag (`git tag --sort=-v:refname | head -1`).

**Steam Workshop REJECTS an upload that reuses an existing version**, so a stale `modinfo.lua` version
is a real ship-blocker — bump it *before* tagging, not after.

## 5. In-engine load-smoke (critical on modmain / require changes)

A bare no-player load-smoke is **not enough** to clear tick-code changes. The server runs with
`pause_when_empty=true`, which freezes `DoPeriodicTask`/`OnUpdate` until a player connects — so a
latent crash in the per-tick broadcast path only surfaces **once someone joins**. To truly smoke a
`modmain.lua` / tick change you must **connect a player** (or temporarily set `pause_when_empty=false`).

Run the smoke whenever the diff touched `modmain.lua` or **added/changed any `require`d module**:
- Push the build to the beta/modtest channel via skill **`partyhud-beta-upload`**
  (`/home/iblis/code/dst/.claude/skills/partyhud-beta-upload/SKILL.md`).
- Connect and exercise it with the hub console tools: `dstc` / `dst-heal` / `dst-revive` / `dst-cave`
  / `dst-fire`.

> **Caveat (current master):** there is an UNSHIPPED internal test-refactor on master that touched
> `modmain.lua` and added forward-`require`s. **The first release carrying it MUST get an in-engine
> load-smoke with a connected player** — do not skip this gate for that release.

## 6. Tag — and what the tag triggers

Only after gates 1–5 pass. Create and push the **annotated** tag `vYYYY.N`:

```bash
git tag -a v2026.11 -m "PartyHud v2026.11"
```

The tag push triggers `.github/workflows/release.yml`, which **re-runs the manifest gate**, assembles
the allowlist content into a `PartyHud2026/` folder, builds `PartyHud2026-<tag>.zip` + `.tar.gz`, and
creates a GitHub Release with both assets attached.

> **Push constraint:** this local clone CANNOT push (no token). Commits AND the release tag reach
> GitHub via the hub fork `~/partyhud-fork` (SSH key), then locally
> `git fetch && git reset --hard origin/master`. See memory `partyhud-2026-mod`.

## 7. Downstream (after the tag/CI — pointer only)

Out of this checklist's core scope, but the next steps are: download the GitHub Release artifact,
upload to the **PUBLIC** Workshop item `3744675705` (the user does the Steam login), then sync prod.
See memories `dst-server-deployment` and `partyhud-beta-uploader`, and skill `partyhud-beta-upload`
for the beta channel. The public item must stay public and untouched until the user uploads.
