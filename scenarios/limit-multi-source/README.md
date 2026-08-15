# limit-multi-source

All live ingestion paths under concurrent load, on a scoped daemon in
its own namespace. Those paths are OTLP gRPC (Job, prefix `g-`), OTLP
HTTP (Job, prefix `h-`), and the Unix NDJSON socket (tracegen sidecar
sharing an emptyDir, prefix `n-`). The host runs `perf-sentinel tempo`
against the lab Tempo as the concurrent batch reader.

## Run

```bash
make verify-limit-multi-source
```

## Asserts

- `otlp_spans_received_total` delta within ±10% of the gRPC + HTTP sends.
- All three live prefixes appear in `/api/export/report` (no starvation).
- `filtered{not_io}` stays flat (the generator emits only I/O spans).
- The tempo subcommand exits 0 in < 120 s while the daemon is loaded.
- The scoped daemon container never restarts.

## Known feedback items

- The NDJSON socket path has no received-spans counter (only
  `events_processed_total` reflects it) - upstream follow-up.
