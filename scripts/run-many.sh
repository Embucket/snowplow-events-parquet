#!/usr/bin/env bash
# Run N consecutive incremental loads via scripts/run-batch.sh, writing each
# resulting parquet file to S3 under a shared prefix.
# Usage:   scripts/run-many.sh [N]   (default N=10)
# Env vars (IMAGE, EVENTS_TOTAL, EVENTS_PER_FILE, KEEP_TSV) pass through to run-batch.sh.
# Override S3_PARQUET_PREFIX to target a different bucket/prefix.
# CONTINUE_ON_ERROR=1 keeps going past failed increments.
# Requires AWS creds in the environment (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
# AWS_REGION) for datafusion-cli to write to S3.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

N="${1:-10}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-0}"
export S3_PARQUET_PREFIX="${S3_PARQUET_PREFIX:-s3://embucket-testdata/snowplow/events500000}"

if ! [[ "$N" =~ ^[0-9]+$ ]] || (( N < 1 )); then
  echo "ERROR: N must be a positive integer (got: $N)" >&2
  exit 2
fi

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

echo "[$(ts)] Starting $N consecutive increments → $S3_PARQUET_PREFIX"
ok=0
fail=0
start=$(date +%s)

for ((i=1; i<=N; i++)); do
  echo "[$(ts)] === increment $i / $N ==="
  if "$SCRIPT_DIR/run-batch.sh"; then
    ok=$((ok+1))
  else
    rc=$?
    fail=$((fail+1))
    echo "[$(ts)] increment $i failed (exit $rc)" >&2
    if [[ "$CONTINUE_ON_ERROR" != "1" ]]; then
      echo "[$(ts)] Aborting (set CONTINUE_ON_ERROR=1 to keep going)" >&2
      echo "[$(ts)] Summary: $ok ok / $fail failed / $((N-i)) skipped"
      exit "$rc"
    fi
  fi
  # RUN_ID has 1-second resolution; ensure the next run gets a unique directory.
  if (( i < N )); then sleep 1; fi
done

elapsed=$(( $(date +%s) - start ))
echo "[$(ts)] Done. $ok ok / $fail failed in ${elapsed}s"
[[ "$fail" -eq 0 ]]
