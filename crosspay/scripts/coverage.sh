#!/usr/bin/env bash
# Enforce minimum line + branch coverage on src/PaymentRouter.sol.
# Usage: bash scripts/coverage.sh [threshold]   (default threshold: 90)
set -euo pipefail

THRESHOLD="${1:-90}"
TARGET="PaymentRouter.sol"

# Run coverage and capture the summary table.
OUTPUT="$(forge coverage --report summary 2>&1)"

# Isolate the row for the target file.
LINE="$(printf '%s\n' "$OUTPUT" | grep -F "$TARGET" | head -n 1)"
if [ -z "$LINE" ]; then
    echo "error: could not find '$TARGET' in coverage output:" >&2
    printf '%s\n' "$OUTPUT" >&2
    exit 1
fi

# Percentages appear in order: % Lines, % Statements, % Branches, % Funcs.
PCTS="$(printf '%s\n' "$LINE" | grep -oE '[0-9]+(\.[0-9]+)?%')"
LINES="$(printf '%s\n' "$PCTS" | sed -n '1p' | tr -d '%')"
BRANCHES="$(printf '%s\n' "$PCTS" | sed -n '3p' | tr -d '%')"
if [ -z "$LINES" ] || [ -z "$BRANCHES" ]; then
    echo "error: could not parse coverage percentages from: $LINE" >&2
    exit 1
fi

echo "coverage: $TARGET lines=${LINES}% branches=${BRANCHES}% (threshold ${THRESHOLD}%)"

fail() {
    echo "error: $1 coverage ${2}% is below the ${THRESHOLD}% threshold" >&2
    exit 1
}

# Fail if either metric is below threshold (float-aware comparison).
if awk -v pct="$LINES" -v thr="$THRESHOLD" 'BEGIN { exit !(pct + 0 < thr + 0) }'; then
    fail "line" "$LINES"
fi
if awk -v pct="$BRANCHES" -v thr="$THRESHOLD" 'BEGIN { exit !(pct + 0 < thr + 0) }'; then
    fail "branch" "$BRANCHES"
fi

echo "coverage gate passed."
