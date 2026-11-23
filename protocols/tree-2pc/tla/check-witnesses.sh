#!/usr/bin/env bash
# Each witness is an invariant claiming some state is unreachable.  TLC must
# VIOLATE it: the counterexample proves the path is reachable.
# Usage: [BASE=<Config>] ./check-witnesses.sh [Witness ...]   (default: all,
# BASE=Coverage)
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
rc=0
for w in "$@"; do
  if [[ ! "$w" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
    echo "Invalid witness name: $w" >&2
    exit 2
  fi
  cfg="Witness_${w}_$$"
  { cat "${BASE:-Coverage}.cfg"; echo "INVARIANT $w"; } > "$cfg.cfg"
  TLC_WORKERS="${TLC_WORKERS:-4}" TLC_HEAP="${TLC_HEAP:-4g}" ./run.sh "$cfg" > "out/$cfg.out" 2>&1
  if grep -q "Invariant $w is violated" "out/$cfg.out"; then
    n=$(grep -cE '^State [0-9]+:' "out/$cfg.out")
    echo "REACHED  $w  (trace of $n states)"
  else
    echo "MISSING  $w  (see out/$cfg.out)"
    rc=1
  fi
  rm -f "$cfg.cfg"
done
exit $rc
