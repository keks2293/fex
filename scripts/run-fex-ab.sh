#!/usr/bin/env bash
# A/B run of RE4 (DX12, proton → vkd3d → Turnip) under a given FEX profile.
#
#   scripts/run-fex-ab.sh <profile> [timeout-sec]
#
# Generates FEX_APP_CONFIG (scripts/make-fex-config.py), exports it and calls
# scripts/run-game.sh patched from the main repo with TAG=fex-<profile> and a
# MangoHud CSV (HUDLOG=timeout, HUDINTERVAL=100). Copies the CSV and logs into
# fex-a7xx/results/re4/ (results are grouped by game name).
#
# FEX_APP_CONFIG is the only knob that FEX arm64ec/wow64 from proton-cachyos
# reads (on-disk configs are seen only by the system FEX). The profile is
# deterministic: the armada-game-launch wrapper is not involved.
set -euo pipefail

PROFILE="${1:?usage: run-fex-ab.sh <profile> [timeout-sec]}"
TIMEOUT="${2:-180}"

FEEX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TURNIP="$(cd "$FEEX/../turnip-a7xx-dx12" && pwd)"
mkdir -p "$FEEX/results/re4"

# Generate the config; the path goes to stdout, the profile description to stderr -> results/fex-cfg.log
CFG="$(python3 "$FEEX/scripts/make-fex-config.py" "$PROFILE" 2>>"$FEEX/results/fex-cfg.log")"
[ -f "$CFG" ] || { echo "no generated config $CFG" >&2; exit 1; }
export FEX_APP_CONFIG="$CFG"
{
  echo "# $(date -Is) profile=$PROFILE"
  cat "$FEEX/results/fex-cfg.log" | tail -2
} >> "$FEEX/results/fex-cfg.log"

# run-game.sh reads TAG / HUDLOG / HUDINTERVAL from the environment
export TAG="fex-${PROFILE}"
export HUDLOG="$TIMEOUT"
export HUDINTERVAL=100

set +e
bash "$TURNIP/scripts/run-game.sh" patched "$TIMEOUT"
RC=$?
set -e

# Move the results into fex-a7xx (MangoHud CSV lives in /tmp/opencode/mangologs — tmpfs)
shopt -s nullglob
for csv in /tmp/opencode/mangologs/*.csv; do
  cp -f "$csv" "$FEEX/results/re4/fps-fex-${PROFILE}.csv"
done
cp -f "$TURNIP/results/game-patched-fex-${PROFILE}.log" "$FEEX/results/re4/" 2>/dev/null || true
cp -f "$TURNIP/results/raw/game-patched-fex-${PROFILE}.log" \
      "$FEEX/results/re4/raw-game-patched-fex-${PROFILE}.log" 2>/dev/null || true

echo
echo "=== fex-a7xx: $PROFILE, exit code $RC ==="
echo "CSV:  $FEEX/results/re4/fps-fex-${PROFILE}.csv"
