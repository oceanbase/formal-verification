#!/usr/bin/env bash
# Each witness is an invariant claiming some state is unreachable.  TLC must
# VIOLATE it: the counterexample proves the path is reachable.
# Usage: [BASE=<Config>] ./check-witnesses.sh [Witness ...]
#   Default suite uses BASE=Coverage; pass BASE=CoverageCircular for
#   NoCircularPrepare and BASE=LiveCoverage for NoLiveCircularCommit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
ALL="NoCommitTombstone NoInternalAbortPropagation NoTransferInRunning \
NoTransferInPrepare NoTransferInCommit NoTDTRetryCommit \
NoTransUnknownOnRecreatedRetry NoAbortOnNewCoordUnknown"
if [[ ! "${BASE:-Coverage}" =~ ^[A-Za-z][A-Za-z0-9_]*$ || ! -f "${BASE:-Coverage}.cfg" ]]; then
  echo "Unknown witness configuration: ${BASE:-Coverage}" >&2
  exit 2
fi
if [ "$#" -eq 0 ]; then set -- $ALL; fi
mkdir -p out
CURRENT_CFG=""
trap '[[ -n "$CURRENT_CFG" ]] && rm -f "$CURRENT_CFG.cfg"' EXIT INT TERM
rc=0
for w in "$@"; do
  if [[ ! "$w" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
    echo "Invalid witness name: $w" >&2
    exit 2
  fi
  CURRENT_CFG="Witness_${w}_$$"
  { cat "${BASE:-Coverage}.cfg"; echo "INVARIANT $w"; } > "$CURRENT_CFG.cfg"
  TLC_WORKERS="${TLC_WORKERS:-4}" TLC_HEAP="${TLC_HEAP:-4g}" ./run.sh "$CURRENT_CFG" > "out/$CURRENT_CFG.out" 2>&1
  if grep -q "Invariant $w is violated" "out/$CURRENT_CFG.out"; then
    n=$(grep -cE '^State [0-9]+:' "out/$CURRENT_CFG.out")
    echo "REACHED  $w  (trace of $n states)"
  else
    echo "MISSING  $w  (see out/$CURRENT_CFG.out)"
    rc=1
  fi
  rm -f "$CURRENT_CFG.cfg"
  CURRENT_CFG=""
done
exit $rc
