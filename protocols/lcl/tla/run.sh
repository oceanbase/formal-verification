#!/usr/bin/env bash
# Model-check one config of MC.tla (or of $MODULE.tla).
# Usage: [MODULE=<Module>] [TLC_WORKERS=4] [TLC_HEAP=4g] ./run.sh <Config> [extra TLC args]
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

WORKERS="${TLC_WORKERS:-4}"
HEAP="${TLC_HEAP:-4g}"
if [[ ! "$WORKERS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid TLC_WORKERS: $WORKERS" >&2
  exit 2
fi
if [[ ! "$HEAP" =~ ^[1-9][0-9]*[kKmMgG]$ ]]; then
  echo "Invalid TLC_HEAP: $HEAP" >&2
  exit 2
fi
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

# -deadlock: terminal states are expected once all cycles are resolved or finite
# period bounds are reached; correctness is checked via invariants and temporal properties.
"$JAVA" "${JVM_ARGS[@]}" -cp "$JAR" tlc2.TLC \
  -deadlock -workers "$WORKERS" -fp 0 \
  -metadir "$METADIR_TLC" \
  -config "$CFG.cfg" "$@" "${MODULE:-MC}.tla"
