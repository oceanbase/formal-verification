#!/usr/bin/env bash
# Model-check one config of Arbitration.tla (or of $MODULE.tla).
# Usage: [MODULE=<Module>] [TLC_WORKERS=8] [TLC_HEAP=12g] [TLC_DIRECT=32g] ./run.sh <Config> [extra TLC args]
#   Local default: ./run.sh Arbitration
#   Large 4F1A:    TLC_WORKERS=15 TLC_HEAP=16g TLC_DIRECT=32g ./run.sh Arbitration4FP2C3
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
HEAP="${TLC_HEAP:-12g}"
# Use a fresh directory so concurrent runs and retained checkpoints are safe.
mkdir -p "$HERE/states"
RUN_DIR=$(mktemp -d "$HERE/states/${CFG}.XXXXXXXX")
METADIR_TLC="$RUN_DIR/states"
TMPDIR_TLC="$RUN_DIR/tmp"
mkdir -p "$TMPDIR_TLC"
trap 'rm -rf "$TMPDIR_TLC"; rmdir "$RUN_DIR" 2>/dev/null || true' EXIT

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

# -deadlock: terminal states are expected (bounded model); we check
# invariants and properties, not deadlock freedom.
"$JAVA" "${JVM_ARGS[@]}" -cp "$JAR" tlc2.TLC \
  -deadlock -workers "$WORKERS" ${TLC_EXTRA[@]+"${TLC_EXTRA[@]}"} \
  -metadir "$METADIR_TLC" \
  -config "$CFG.cfg" "$@" "${MODULE:-Arbitration}.tla"
