#!/bin/sh
# Build and run a fuzzer by name.
#
# Usage:
#   ./test/fuzzers/run.sh html                        # build & run html fuzzer (1 core, 60s)
#   ./test/fuzzers/run.sh ast --timeout 300           # run for 300 seconds
#   ./test/fuzzers/run.sh heal --cores 4              # run heal fuzzer with 4 cores
#   ./test/fuzzers/run.sh html --cores 4 --timeout 0  # run forever with 4 cores
#
# Corpus is stored in test/fuzzers/corpus/<name>/ (gitignored).
# Seed corpus from test/fuzzers/seed-corpus/ is used as read-only seed.

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FUZZ_OUT="${FUZZ_OUT_DIR:-$ROOT/fuzz-out}"
CORPUS_DIR="$ROOT/test/fuzzers/corpus"
SEED_DIR="$ROOT/test/fuzzers/seed-corpus"

# Defaults
MAX_TIME=60
CORES=1
TARGET=""

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --cores)    CORES="$2"; shift 2 ;;
        --timeout)  MAX_TIME="$2"; shift 2 ;;
        -*)         echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [ -z "$TARGET" ]; then
                TARGET="$1"; shift
            else
                echo "Unexpected argument: $1" >&2; exit 1
            fi
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <html|ast|ansi|text|meta|heal> [--timeout SECONDS] [--cores N]" >&2
    exit 1
fi

case "$TARGET" in
    html|ast|ansi|text|meta|heal) ;;
    *) echo "Unknown target: $TARGET (expected: html, ast, ansi, text, meta, heal)" >&2; exit 1 ;;
esac

BINARY="$FUZZ_OUT/fuzz-md$TARGET"

# Build the fuzzer
"$ROOT/test/fuzzers/build.sh" "$TARGET"

# Create corpus directory
mkdir -p "$CORPUS_DIR/$TARGET"

ARTIFACT_DIR="$FUZZ_OUT/artifacts/$TARGET"
mkdir -p "$ARTIFACT_DIR"

echo "Running fuzz-md$TARGET (-fork=$CORES), artifacts in $ARTIFACT_DIR..."
while true; do
    "$BINARY" "$CORPUS_DIR/$TARGET" "$SEED_DIR" \
        -max_total_time="$MAX_TIME" \
        -fork="$CORES" \
        -artifact_prefix="$ARTIFACT_DIR/" || true
    echo "Fuzzer exited, restarting..."
done
