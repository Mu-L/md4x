#!/bin/sh
# Deduplicate fuzz crash artifacts by stack trace signature.
#
# Usage:
#   ./test/fuzzers/dedup.sh                    # dedup all artifacts
#   ./test/fuzzers/dedup.sh fuzz-out/artifacts  # custom artifact dir
#
# Reproduces each crash/oom against all fuzzers, groups by unique
# stack trace (top 3 frames), and prints a summary. Keeps one
# representative per unique bug and optionally removes duplicates.
#
# Requires fuzzers to be built first (./test/fuzzers/build.sh).

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FUZZ_OUT="${FUZZ_OUT_DIR:-$ROOT/fuzz-out}"
ARTIFACT_DIR="${1:-$FUZZ_OUT/artifacts}"
FUZZERS="fuzz-mdhtml fuzz-mdast fuzz-mdansi fuzz-mdtext fuzz-mdmeta fuzz-mdheal"

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "No artifact directory: $ARTIFACT_DIR" >&2
    exit 1
fi

# Check that fuzzers are built
for f in $FUZZERS; do
    if [ ! -x "$FUZZ_OUT/$f" ]; then
        echo "Fuzzer $f not found. Run ./test/fuzzers/build.sh first." >&2
        exit 1
    fi
done

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Collect all crash/oom files recursively
find "$ARTIFACT_DIR" -type f \( -name 'crash-*' -o -name 'oom-*' \) | sort > "$TMPDIR/all_artifacts"

total=$(wc -l < "$TMPDIR/all_artifacts")
echo "Found $total artifacts in $ARTIFACT_DIR"
echo

n=0
while IFS= read -r artifact; do
    n=$((n + 1))
    name=$(basename "$artifact")
    printf "\r[%d/%d] %s" "$n" "$total" "$name" >&2

    sig=""
    matched_fuzzer=""

    for f in $FUZZERS; do
        output=$("$FUZZ_OUT/$f" "$artifact" 2>&1 || true)

        # Check for OOM
        if echo "$output" | grep -q 'out-of-memory'; then
            sig="OOM|$f"
            matched_fuzzer="$f"
            break
        fi

        # Check for crash (ASAN error or signal)
        error_type=$(echo "$output" | grep -oP 'ERROR: \S+ \K\S+' | head -1)
        if [ -n "$error_type" ]; then
            # Extract top 3 frames as signature (strip addresses)
            frames=$(echo "$output" | grep -E '^\s+#[0-9]' | head -3 \
                | sed 's/0x[0-9a-f]*/@/g; s/#[0-9]* @/#N @/' \
                | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' \
                | tr '\n' '|')
            sig="$error_type|$frames"
            matched_fuzzer="$f"
            break
        fi
    done

    if [ -z "$sig" ]; then
        sig="NO_REPRO"
        matched_fuzzer="-"
    fi

    echo "$sig	$matched_fuzzer	$artifact" >> "$TMPDIR/results"
done < "$TMPDIR/all_artifacts"

printf "\r%${COLUMNS:-80}s\r" "" >&2

# Group by signature
echo "=== Unique bugs ==="
echo

bug_id=0
sort -t'	' -k1,1 "$TMPDIR/results" | awk -F'\t' '
{
    sig = $1
    fuzzer = $2
    file = $3
    if (sig != prev_sig) {
        if (NR > 1) printf "\n"
        bug_id++
        prev_sig = sig
        count = 0
    }
    count++
    if (count == 1) {
        printf "Bug #%d (%s)\n", bug_id, fuzzer
        printf "  Signature: %s\n", sig
        printf "  Representative: %s\n", file
        first_file = file
    }
    files[bug_id] = files[bug_id] ? files[bug_id] "\n" file : file
    counts[bug_id] = count
    bug_ids[bug_id] = bug_id
    reps[bug_id] = first_file
}
END {
    printf "\n"
    for (i = 1; i <= bug_id; i++) {
        printf "  Bug #%d: %d artifact(s)\n", i, counts[i]
    }
    printf "\n  Total: %d artifacts -> %d unique bugs\n", NR, bug_id
}
'

echo
echo "--- Duplicates ---"
echo

# Print duplicates (all but first per group) for optional removal
sort -t'	' -k1,1 "$TMPDIR/results" | awk -F'\t' '
{
    sig = $1
    file = $3
    if (sig != prev_sig) {
        prev_sig = sig
        next  # skip representative
    }
    print file
}
' > "$TMPDIR/duplicates"

dup_count=$(wc -l < "$TMPDIR/duplicates")
echo "$dup_count duplicate artifact(s)."

if [ "$dup_count" -gt 0 ]; then
    echo
    echo "To remove duplicates, run:"
    echo "  cat <<'DUPES' | xargs rm"
    cat "$TMPDIR/duplicates"
    echo "DUPES"
fi
