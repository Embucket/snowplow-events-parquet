# generate-snowplow-events

Periodic batch generator that produces Snowplow-canonical enriched events as Parquet files. Each invocation creates one **incremental load** under `runs/<RUN_ID>/parquet/`. Downstream consumers can pick up new directories without overlap.

## Pipeline

```
  +--------------------------+   TSV   +-----------------+   Parquet
  | snowplow-event-generator | ──────▶ |  datafusion-cli | ─────────▶  runs/<id>/parquet/
  |   (Docker container)     |  (\t)   |   CSV → COPY    |
  +--------------------------+         +-----------------+
```

- Generator: `localhost/snowplow-event-generator:latest` (built from `../snowplow-event-generator/Dockerfile`).
- Converter: `datafusion-cli` (system install).

## Layout

```
config/generator.hocon        HOCON template; __SEED__/__EVENTS_TOTAL__/__EVENTS_PER_FILE__ substituted per run
sql/schema.sql                Canonical 131-column atomic.events DDL (reference / source of truth)
sql/tsv_to_parquet.sql.tmpl   External CSV table (all VARCHAR) + COPY with typed CASTs
scripts/run-batch.sh          Orchestrates one full incremental load
runs/<RUN_ID>/                Per-run output directory (gitignored)
  generator.hocon               rendered config used for this run
  tsv_to_parquet.sql            rendered SQL with absolute paths
  tsv/enriched/enriched_NNNN    raw TSV (deleted on success unless KEEP_TSV=1)
  parquet/*.parquet             final output
  run.log                       full stdout/stderr from generator + datafusion
```

## Run a single batch

```bash
./scripts/run-batch.sh
```

Defaults: 5,000,000 events, 500,000 events per TSV file → ~1 GB parquet.

### Environment overrides

| Variable          | Default                                          | Purpose                                                        |
| ----------------- | ------------------------------------------------ | -------------------------------------------------------------- |
| `EVENTS_TOTAL`    | `5000000`                                        | How many events to generate                                    |
| `EVENTS_PER_FILE` | `500000`                                         | TSV rotation size                                              |
| `KEEP_TSV`        | `0` (delete on success)                          | Set to `1` to keep raw TSV for debugging                       |
| `IMAGE`           | `localhost/snowplow-event-generator:latest`      | Override generator image (e.g. for a tagged build)             |

### Smoke test

```bash
EVENTS_TOTAL=10000 EVENTS_PER_FILE=10000 ./scripts/run-batch.sh
```

Should finish in seconds and produce `runs/<id>/parquet/*.parquet`.

## Schedule with cron

The script is cron-safe (absolute paths, no interactive prompts, all output to `run.log`). Example: hourly batches.

```cron
# m h dom mon dow command
0 * * * * /home/work/workspace/github/generate-snowplow-events/scripts/run-batch.sh
```

Install with `crontab -e`. To keep disk usage bounded, prune old runs separately, e.g.:

```cron
30 3 * * * find /home/work/workspace/github/generate-snowplow-events/runs -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
```

## Inspect output

```bash
# Row count for a run
datafusion-cli -c "SELECT COUNT(*) FROM 'runs/<RUN_ID>/parquet/'"

# Schema (should print 131 columns)
datafusion-cli -c "DESCRIBE 'runs/<RUN_ID>/parquet/'"

# Sample rows
datafusion-cli -c "SELECT app_id, event, collector_tstamp FROM 'runs/<RUN_ID>/parquet/' LIMIT 5"
```

## Schema notes

The TSV column order matches the Snowplow Analytics SDK `Event.toTsv` canonical layout (131 columns). The runtime SQL in `sql/tsv_to_parquet.sql.tmpl` reads every column as `VARCHAR` to avoid CSV parse errors on Snowplow's empty-string-as-NULL convention, then casts to the right types in the `COPY` projection — so the parquet output has proper `TIMESTAMP`, `INT`, `DOUBLE`, and `BOOLEAN` columns. `sql/schema.sql` is the canonical reference and is not executed.

## Sizing

- Snowplow enriched TSV row ≈ 1–3 KB.
- Parquet (zstd-3) ≈ 4–8× compression → ≈ 200–500 B/row.
- 5M rows ≈ 0.7–1.5 GB parquet per run.

## Cleanup

```bash
# Remove all completed runs
rm -rf runs/*
```
