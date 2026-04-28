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

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="runs/$RUN_ID"
TSV_DIR_ABS="$PROJECT_ROOT/$RUN_DIR/tsv"
PARQUET_DIR_ABS="$PROJECT_ROOT/$RUN_DIR/parquet"
LOG="$PROJECT_ROOT/$RUN_DIR/run.log"

mkdir -p "$TSV_DIR_ABS" "$PARQUET_DIR_ABS"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

log "RUN_ID=$RUN_ID  events=$EVENTS_TOTAL  per_file=$EVENTS_PER_FILE  image=$IMAGE"

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
  -e "s|__PARQUET_DIR__|$PARQUET_DIR_ABS|g" \
  sql/tsv_to_parquet.sql.tmpl > "$RUN_DIR/tsv_to_parquet.sql"

# 4. Convert TSV → Parquet.
log "Running datafusion-cli…"
datafusion-cli -f "$RUN_DIR/tsv_to_parquet.sql" >> "$LOG" 2>&1

if ! ls "$PARQUET_DIR_ABS"/*.parquet >/dev/null 2>&1; then
  log "ERROR: no parquet files produced under $PARQUET_DIR_ABS"
  exit 1
fi
log "Parquet output: $(find "$PARQUET_DIR_ABS" -name '*.parquet' | wc -l) file(s) ($(du -sh "$PARQUET_DIR_ABS" | cut -f1))"

# 5. Cleanup TSV unless explicitly kept.
if [[ "$KEEP_TSV" != "1" ]]; then
  rm -rf "$TSV_DIR_ABS"
  log "Removed TSV directory."
else
  log "KEEP_TSV=1 — leaving TSV in place."
fi

log "Done. Output in $RUN_DIR/parquet/"
