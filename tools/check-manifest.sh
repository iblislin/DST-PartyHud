#!/usr/bin/env bash
#
# check-manifest.sh — standalone validator for release-manifest.txt.
#
# Runs outside CI (the partyhud-release-preflight skill invokes it) and is also the
# gate the release workflow runs (.github/workflows/release.yml). It guards against the
# production accident where a runtime-required Lua module is silently left out of the
# release archive (a missing module = the mod fails to load in a live game).
#
# Checks:
#   HARD A — every manifest path exists on disk.
#   HARD B — every repo-local required module is covered by the manifest.
#   SOFT   — warn about git-tracked top-level files that are neither covered by the
#            manifest nor in the known dev/excluded set.
#
# Exit 0 only if both HARD checks pass; exit 1 if any HARD check fails (after printing
# all failures, not stopping at the first).

set -euo pipefail

# Work from the repo root regardless of CWD (the script lives in tools/).
cd "$(dirname "$0")/.."

MANIFEST="release-manifest.txt"

# parse_manifest — emit one manifest path per line on stdout.
#
# Parse rules MUST match the assembly loop in .github/workflows/release.yml so the
# validator and the CI packer never diverge (single source of truth):
#   line="${raw%%#*}"  then trim leading/trailing whitespace with sed; skip blanks.
parse_manifest() {
  local raw line
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%%#*}"                 # drop inline/full-line comments
    line="$(printf '%s' "$line" | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//')"
    [ -z "$line" ] && continue
    printf '%s\n' "$line"
  done < "$MANIFEST"
}

# Load the manifest paths into an array, reused by every check.
manifest_paths=()
while IFS= read -r p; do
  manifest_paths+=("$p")
done < <(parse_manifest)

fail=0

# ---------------------------------------------------------------------------
# HARD CHECK A — every manifest path exists.
# ---------------------------------------------------------------------------
a_ok=1
a_missing=()
for p in "${manifest_paths[@]}"; do
  if [ ! -e "$p" ]; then
    a_ok=0
    a_missing+=("$p")
  fi
done
if [ "$a_ok" -eq 1 ]; then
  echo "✓ HARD A: all ${#manifest_paths[@]} manifest path(s) exist on disk."
else
  echo "✗ HARD A: manifest lists path(s) that do not exist in the repo:"
  for p in "${a_missing[@]}"; do
    echo "    - $p"
  done
  fail=1
fi

# ---------------------------------------------------------------------------
# Helper: is candidate file covered by the manifest?
# "Covered" = the path equals a listed entry, OR is underneath a listed directory
# (some listed entry D satisfies cand == D or cand begins with "D/").
# ---------------------------------------------------------------------------
is_covered() {
  local cand="$1" d
  for d in "${manifest_paths[@]}"; do
    if [ "$cand" = "$d" ] || [ "${cand#"$d"/}" != "$cand" ]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# HARD CHECK B — every repo-local required module is covered by the manifest.
# Grep modmain.lua + all of scripts/ for require calls, extract the quoted name,
# dedupe. For each name, cand="scripts/${name}.lua". If cand exists in the repo it
# MUST be covered. Engine modules (cand does not exist) are ignored.
# ---------------------------------------------------------------------------
b_ok=1
b_offenders=()
require_ere='require[[:space:]]*\(?[[:space:]]*['"'"'"][^'"'"'"]+['"'"'"]'

# Collect deduped required names.
names="$(
  grep -rhoE "$require_ere" modmain.lua scripts/ 2>/dev/null \
    | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/" \
    | sort -u
)"

while IFS= read -r name; do
  [ -z "$name" ] && continue
  cand="scripts/${name}.lua"
  # Engine modules have no corresponding repo file — ignore them.
  [ -e "$cand" ] || continue
  if ! is_covered "$cand"; then
    b_ok=0
    b_offenders+=("$name -> $cand")
  fi
done <<< "$names"

if [ "$b_ok" -eq 1 ]; then
  echo "✓ HARD B: all repo-local required modules are covered by the manifest."
else
  echo "✗ HARD B: required module(s) NOT covered by release-manifest.txt"
  echo "          (a missing module = the mod fails to load = production accident):"
  for o in "${b_offenders[@]}"; do
    echo "    - $o"
  done
  fail=1
fi

# ---------------------------------------------------------------------------
# SOFT WARN — unclassified top-level files.
# List git-tracked top-level entries that are NEITHER covered by the manifest NOR in
# the known dev/excluded set. Also treat any *.jpg and the .git dir as excluded.
# Soft warnings do NOT change the exit code.
# ---------------------------------------------------------------------------
known_exclude=(
  spec docs .claude .github tools README.md FEATURE-IDEAS.md preview.jpg
  .busted .luacheckrc .gitignore .git
  release-manifest.txt   # the manifest itself is release/CI infra, not shipped content
)

is_known_exclude() {
  local entry="$1" e
  for e in "${known_exclude[@]}"; do
    [ "$entry" = "$e" ] && return 0
  done
  # Any *.jpg is excluded.
  case "$entry" in
    *.jpg) return 0 ;;
  esac
  return 1
}

# Top-level git-tracked entries (first path component, deduped). Fall back to a plain
# directory listing if git is unavailable / not a repo.
if top_entries="$(git ls-files 2>/dev/null)" && [ -n "$top_entries" ]; then
  top_entries="$(printf '%s\n' "$top_entries" | sed -E 's#/.*##' | sort -u)"
else
  # find (not ls) handles non-alphanumeric filenames safely; strip the leading "./".
  top_entries="$(find . -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -u)"
fi

unclassified=()
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  is_covered "$entry" && continue
  is_known_exclude "$entry" && continue
  unclassified+=("$entry")
done <<< "$top_entries"

if [ "${#unclassified[@]}" -eq 0 ]; then
  echo "✓ SOFT: no new, unclassified top-level files."
else
  echo "⚠ SOFT WARNING: new, unclassified top-level file(s) — decide include/exclude"
  echo "  and update release-manifest.txt or the known-exclude set in this script:"
  for u in "${unclassified[@]}"; do
    echo "    - $u"
  done
fi

# ---------------------------------------------------------------------------
echo
if [ "$fail" -eq 0 ]; then
  echo "RESULT: ✓ both HARD checks passed."
  exit 0
else
  echo "RESULT: ✗ one or more HARD checks failed."
  exit 1
fi
