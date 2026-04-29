#!/usr/bin/env bash
# One Snowplow incremental load: generate TSV via Docker → convert to Parquet via datafusion-cli.
# Cron-friendly: uses absolute paths, logs to runs/<id>/run.log, exits non-zero on any failure.
set -euo pipefail

# Resolve project root regardless of where this script was invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

IMAGE="${IMAGE:-localhost/snowplow-event-generator:latest}"
EVENTS_TOTAL="${EVENTS_TOTAL:-5000000}"
EVENTS_PER_FILE="${EVENTS_PER_FILE:-500000}"
KEEP_TSV="${KEEP_TSV:-0}"
# When set, parquet is written directly to <prefix>/<RUN_ID>.parquet on S3.
# Requires datafusion-cli to have AWS creds (env vars: AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, AWS_REGION, optionally AWS_SESSION_TOKEN).
S3_PARQUET_PREFIX="${S3_PARQUET_PREFIX:-}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="runs/$RUN_ID"
TSV_DIR_ABS="$PROJECT_ROOT/$RUN_DIR/tsv"
PARQUET_DIR_ABS="$PROJECT_ROOT/$RUN_DIR/parquet"
LOG="$PROJECT_ROOT/$RUN_DIR/run.log"

if [[ -n "$S3_PARQUET_PREFIX" ]]; then
  PARQUET_DEST="${S3_PARQUET_PREFIX%/}/${RUN_ID}.parquet"
  mkdir -p "$TSV_DIR_ABS"
else
  PARQUET_DEST="$PARQUET_DIR_ABS/data.parquet"
  mkdir -p "$TSV_DIR_ABS" "$PARQUET_DIR_ABS"
fi

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

log "RUN_ID=$RUN_ID  events=$EVENTS_TOTAL  per_file=$EVENTS_PER_FILE  image=$IMAGE  dest=$PARQUET_DEST"

# 1. Render generator config with run-specific seed and sizing.
SEED="$(date +%s)"
sed \
  -e "s|__SEED__|$SEED|g" \
  -e "s|__EVENTS_TOTAL__|$EVENTS_TOTAL|g" \
  -e "s|__EVENTS_PER_FILE__|$EVENTS_PER_FILE|g" \
  config/generator.hocon > "$RUN_DIR/generator.hocon"

# 2. Run the snowplow-event-generator container.
log "Running snowplow-event-generator…"
docker run --rm \
  -v "$TSV_DIR_ABS:/out:Z" \
  -v "$PROJECT_ROOT/$RUN_DIR/generator.hocon:/config.hocon:ro,Z" \
  "$IMAGE" \
  --config /config.hocon \
  >> "$LOG" 2>&1

TSV_GLOB="$TSV_DIR_ABS/enriched"
if ! ls "$TSV_GLOB"/enriched_* >/dev/null 2>&1; then
  log "ERROR: no TSV files produced under $TSV_GLOB"
  exit 1
fi
log "Generator wrote $(find "$TSV_GLOB" -type f | wc -l) TSV file(s) ($(du -sh "$TSV_GLOB" | cut -f1))"

# 3. Render the SQL template with absolute paths.
sed \
  -e "s|__TSV_DIR__|$TSV_GLOB|g" \
  -e "s|__PARQUET_DEST__|$PARQUET_DEST|g" \
  sql/tsv_to_parquet.sql.tmpl > "$RUN_DIR/tsv_to_parquet.sql"

# 4. Convert TSV → Parquet.
log "Running datafusion-cli…"
datafusion-cli -f "$RUN_DIR/tsv_to_parquet.sql" >> "$LOG" 2>&1

if [[ -n "$S3_PARQUET_PREFIX" ]]; then
  log "Parquet output: $PARQUET_DEST (uploaded by datafusion-cli)"
else
  if [[ ! -f "$PARQUET_DEST" ]]; then
    log "ERROR: parquet file not produced at $PARQUET_DEST"
    exit 1
  fi
  log "Parquet output: $PARQUET_DEST ($(du -h "$PARQUET_DEST" | cut -f1))"
fi

# 5. Cleanup TSV unless explicitly kept.
if [[ "$KEEP_TSV" != "1" ]]; then
  rm -rf "$TSV_DIR_ABS"
  log "Removed TSV directory."
else
  log "KEEP_TSV=1 — leaving TSV in place."
fi

log "Done. Output: $PARQUET_DEST"
