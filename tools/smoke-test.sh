#!/usr/bin/env bash
# Load smoke test for a DST mod (PartyHud 2026).
# Spins up an ISOLATED throwaway dedicated server (offline, single Master shard,
# bridge net / no published ports, seccomp=unconfined), loads this repo as a
# LOCAL mod, generates a world, and checks the log for a clean load.
# PASS = mod registered + world generated + no Lua errors.
#
# Requires: docker (+ the DST server image already pullable). Run from anywhere:
#   ./tools/smoke-test.sh
# Override the image with:  IMAGE=... ./tools/smoke-test.sh
set -euo pipefail

IMAGE="${IMAGE:-superjump22/dontstarvetogether:latest}"
MODNAME="smokemod"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dst-smoke.XXXXXX")"
CONTAINER="dst-smoke-$$"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  # world/save files end up root-owned (written from inside the container)
  docker run --rm -v "$WORK":/w alpine rm -rf /w >/dev/null 2>&1 || rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

CL="$WORK/save/Cluster_1"
mkdir -p "$CL/Master" "$WORK/mods/$MODNAME"
# copy the mod, minus VCS / dev / non-mod files
( cd "$REPO" && tar --exclude=./.git --exclude=./.github --exclude=./tools -cf - . ) \
  | tar -xf - -C "$WORK/mods/$MODNAME"

cat > "$CL/cluster.ini" <<'INI'
[GAMEPLAY]
game_mode = survival
max_players = 6
[NETWORK]
cluster_name = SMOKE-TEST
offline_cluster = true
[MISC]
console_enabled = true
[SHARD]
shard_enabled = false
INI

cat > "$CL/Master/server.ini" <<'INI'
[NETWORK]
server_port = 11999
[SHARD]
is_master = true
[ACCOUNT]
encode_user_path = true
INI

cat > "$CL/Master/modoverrides.lua" <<LUA
return { ["$MODNAME"] = { enabled = true } }
LUA

echo ">> starting throwaway DST server ($CONTAINER) with the mod ..."
docker run -d --name "$CONTAINER" \
  --security-opt seccomp=unconfined \
  -v "$WORK/save:/home/steam/dst/save" \
  -v "$WORK/mods:/home/steam/dst/game/mods" \
  "$IMAGE" \
  -skip_update_server_mods \
  -persistent_storage_root "/home/steam/dst" \
  -conf_dir "save" -cluster "Cluster_1" -shard "Master" >/dev/null

echo ">> waiting for world generation + mod load ..."
reached=""
for i in $(seq 1 45); do
  sleep 4
  L="$(docker logs "$CONTAINER" 2>&1 | tr '\r' '\n')"
  echo "$L" | grep -qiE "Sim paused|World generated on build" && { reached=1; break; }
  echo "$L" | grep -qiE "Disabling all mods|Server failed to start" && break
done
L="$(docker logs "$CONTAINER" 2>&1 | tr '\r' '\n')"

echo "----- mod load -----"
echo "$L" | grep -iE "Loading mod:|Registering Mod " | grep -vi "no mods" || echo "(no mod-load lines!)"
echo "--------------------"

errors="$(echo "$L" | grep -iE "LUA ERROR|SCRIPT ERROR|stack traceback|attempt to (index|call|perform|compare|concatenate)|Disabling all mods" || true)"
fail=0
[ -n "$reached" ] || { echo "FAIL: server never reached world-gen / Sim paused"; fail=1; }
echo "$L" | grep -qi "Registering Mod " || { echo "FAIL: mod was not registered"; fail=1; }
[ -z "$errors" ] || { echo "FAIL: Lua errors detected:"; echo "$errors" | head -20; fail=1; }

if [ "$fail" = "0" ]; then
  echo "PASS: mod loaded clean (registered + world generated + no Lua errors)"
  exit 0
fi
echo "===== last 25 log lines ====="; echo "$L" | tail -25
exit 1
