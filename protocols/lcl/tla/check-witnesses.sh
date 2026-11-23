#!/usr/bin/env bash
# Each witness is an invariant claiming a target state is unreachable.
# TLC must VIOLATE it: the counterexample trace proves the scenario is reachable.
# Usage: ./check-witnesses.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
mkdir -p out
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
  local cfg="Witness_${w}_$$"
  { grep -vE '^(PROPERTY|INVARIANT)' "$base.cfg"; echo "INVARIANT $w"; } > "$cfg.cfg"
  TLC_WORKERS="${TLC_WORKERS:-2}" TLC_HEAP="${TLC_HEAP:-2g}" ./run.sh "$cfg" > "out/$cfg.out" 2>&1
  if grep -q "Invariant $w is violated" "out/$cfg.out"; then
    local n
    n=$(grep -cE '^State [0-9]+:' "out/$cfg.out")
    echo "REACHED  $w  (via $base, trace of $n states)"
  else
    echo "MISSING  $w  (via $base, see out/$cfg.out)"
    rc=1
  fi
  rm -f "$cfg.cfg"
}

run_witness RoundHybridStage0  NoStage0LocalDetect
run_witness RoundAnnulusTail   NoStage0RemotePush
run_witness RoundAnnulusTail   NoAnnulusHighAPBlocked
run_witness RoundAnnulusTail   NoDeadlockResolved
run_witness LivenessChained    NoChainedMultiPeriod
run_witness AsyncMultiCycleSCC NoAsyncTwoVictimsInOneSCC

exit $rc
