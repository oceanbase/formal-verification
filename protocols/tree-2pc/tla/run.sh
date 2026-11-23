#!/usr/bin/env bash
# Model-check one config of Tree2PC.tla (or of $MODULE.tla).
# Usage: [MODULE=<Module>] [TLC_WORKERS=8] [TLC_HEAP=8g] [TLC_DIRECT=16g] ./run.sh <Config> [extra TLC args]
#   Local default: ./run.sh Tree2PCTransfer
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
JAVA="${JAVA:-java}"
JAR="${TLA2TOOLS:-$HERE/tla2tools.jar}"
CFG="${1:?usage: run.sh <Config> [extra TLC args]}"
shift
if [[ ! "$CFG" =~ ^[A-Za-z][A-Za-z0-9_]*$ || ! -f "$HERE/$CFG.cfg" ]]; then
  echo "Unknown configuration: $CFG" >&2
  exit 2
fi
if [[ ! -f "$JAR" ]]; then
  echo "TLC jar not found. Follow the setup instructions in README.md." >&2
  exit 2
fi
cd "$HERE"

WORKERS="${TLC_WORKERS:-8}"
HEAP="${TLC_HEAP:-8g}"
mkdir -p "$HERE/states"
RUN_DIR=$(mktemp -d "$HERE/states/${CFG}.XXXXXXXX")
METADIR_TLC="$RUN_DIR/states"
TMPDIR_TLC="$RUN_DIR/tmp"
mkdir -p "$TMPDIR_TLC"
trap 'rm -rf "$RUN_DIR" 2>/dev/null || true' EXIT

JVM_ARGS=(
  "-Xmx$HEAP"
  "-Djava.io.tmpdir=$TMPDIR_TLC"
  "-XX:+UseParallelGC"
)
TLC_EXTRA=()
if [ -n "${TLC_DIRECT:-}" ]; then
  JVM_ARGS+=(
    "-XX:MaxDirectMemorySize=$TLC_DIRECT"
    "-XX:ParallelGCThreads=2"
    "-Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet"
  )
  TLC_EXTRA+=("-fp" "0" "-fpbits" "1" "-checkpoint" "15")
fi

# -deadlock: terminal states are expected once the transaction completes and
# contexts reach TOMBSTONE; correctness is checked via invariants and properties.
"$JAVA" "${JVM_ARGS[@]}" -cp "$JAR" tlc2.TLC \
  -deadlock -workers "$WORKERS" ${TLC_EXTRA[@]+"${TLC_EXTRA[@]}"} \
  -metadir "$METADIR_TLC" \
  -config "$CFG.cfg" "$@" "${MODULE:-Tree2PC}.tla"
