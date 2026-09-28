# ack-store-fsgroup-root

The daemon's start-up chmod of its ack store directory, against the volume
shape a Kubernetes `fsGroup` leaves behind.

## Why it exists

At start the daemon tries to tighten the directory of `acks.jsonl` to 0700.
The Helm chart puts the ack store at the root of its persistent volume, and
under the pod's `fsGroup` the kubelet leaves that root owned by root, group
`fsGroup`, mode 2775. The daemon runs as 65534 and cannot chmod a directory it
does not own, so up to 0.25.2 every start in the chart logged
`could not tighten ack store parent directory to 0700` at warn level, about
something the operator cannot and need not fix.

0.25.3 logs that refusal at debug when the directory is not writable by
others. A world-writable directory still warns, as does any other chmod
failure. The ack file keeps its 0600 mode.

## What it asserts

| id | assertion |
|----|-----------|
| F1 | fsGroup shape (`root:65534 2775`): no warning about the ack store directory at start |
| F2 | the same start at `RUST_LOG=debug` logs the refusal at debug, not warn |
| F3 | an ack posted to that daemon answers 201 |
| F4 | `acks.jsonl` is 600 and owned by 65534, the directory is left at 2775 `root:65534` |
| W1 | world-writable (`root:65534 2777`): the warning stays |
| O1 | a directory the daemon owns (`65534:65534 2775`): no ack store log line, tightened to 700 |

Run against 0.25.2 the scenario fails F1 and F2 and passes the other four.

## How it reproduces the volume

No cluster. A Docker volume prepared by a root `busybox` container gets the
owner, group and mode the kubelet gives a volume root under `fsGroup: 65534`.
The daemon image then runs on it as `65534:65534`, the chart's
`securityContext`, with `[daemon.ack] storage_path = "/data/acks.jsonl"`, the
path the chart writes.

## Run

```bash
PERF_SENTINEL_IMAGE=perf-sentinel:<local tag> make verify-ack-store-fsgroup-root
```

Needs Docker. The image resolves through `scripts/resolve-image.sh`, so
`PERF_SENTINEL_VERSION=0.25.2` runs the control above. Around 15 seconds.

## Watch out

**The non-loopback warning prints twice.** The daemon listens on `0.0.0.0` here
so the published port reaches it, and 0.25.2 and 0.25.3 both log
`Daemon configured to listen on non-loopback address` twice at start. The
assertions match the ack store messages only.
