#!/usr/bin/env bash
# Each witness is an invariant claiming a target state is unreachable.
# Base safety invariants remain active; TLC must VIOLATE the witness invariant
# itself, proving a safety-preserving trace reaches the target scenario.
# Usage: ./check-witnesses.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
mkdir -p "$HERE/out"
WORK_DIR=$(mktemp -d "$HERE/out/witness.XXXXXXXX")
trap 'rm -rf "$WORK_DIR" 2>/dev/null || true' EXIT
rc=0

run_witness() {
  local base="$1"
  local w="$2"
  if [[ ! "$base" =~ ^[A-Za-z][A-Za-z0-9_]*$ || ! -f "$base.cfg" ]]; then
    echo "Unknown base configuration: $base" >&2
    exit 2
  fi
  if [[ ! "$w" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
    echo "Invalid witness name: $w" >&2
    exit 2
  fi
  local cfg="Witness_${w}"
  local out_file="$WORK_DIR/${cfg}.out"
  { grep -vE '^PROPERTY' "$base.cfg"; echo "INVARIANT $w"; } > "$HERE/$cfg.cfg"
  TLC_WORKERS="${TLC_WORKERS:-2}" TLC_HEAP="${TLC_HEAP:-2g}" ./run.sh "$cfg" > "$out_file" 2>&1
  local run_rc=$?
  rm -f "$HERE/$cfg.cfg"
  if [[ "$run_rc" -eq 12 ]] && grep -q "Invariant $w is violated" "$out_file"; then
    local n
    n=$(grep -cE '^State [0-9]+:' "$out_file")
    echo "REACHED  $w  (via $base, trace of $n states)"
  else
    echo "MISSING  $w  (via $base, rc=$run_rc)"
    rc=1
  fi
}

run_witness RoundHybridStage0  NoStage0LocalDetect
run_witness RoundAnnulusTail   NoStage0RemotePush
run_witness RoundAnnulusTail   NoAnnulusHighAPBlocked
run_witness RoundAnnulusTail   NoDeadlockResolved
run_witness LivenessChained    NoChainedMultiPeriod
run_witness AsyncMultiCycleSCC NoAsyncTwoVictimsInOneSCC

exit $rc
