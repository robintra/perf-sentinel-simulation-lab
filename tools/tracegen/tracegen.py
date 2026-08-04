#!/usr/bin/env python3
"""tracegen: parameterized trace load generator with real I/O semantics.

Why it exists: telemetrygen emits generic spans without db.statement or
http.url, so perf-sentinel filters every one of them as not_io and the
detection/scoring path is never loaded. tracegen generalizes the
hand-built protobuf fixture of daemon-analysis-shedding into a streaming
generator: every retained span carries SQL or HTTP semantics, traces are
shaped after the real anti-pattern catalog, and the run ends with a JSON
report of exactly what was sent so verify.sh can reconcile daemon
counters against ground truth.

Protocols:
  http-pb        OTLP/HTTP protobuf POST to <endpoint>/v1/traces
  grpc           OTLP/gRPC to <endpoint> (host:port)
  ndjson-socket  newline-delimited SpanEvent arrays on a Unix socket
  dump-native    perf-sentinel native JSON files (SpanEvent array)
  dump-jaeger    Jaeger export JSON files
  dump-zipkin    Zipkin v2 JSON files

The dump modes are stdlib-only. http-pb and grpc need opentelemetry-proto
(and grpcio for grpc), pinned in requirements.txt.

--compression {none,gzip,deflate} applies to http-pb (Content-Encoding) and
grpc (grpc-encoding). It is what exercises the daemon's decompression paths:
a real exporter compresses by default, and the lab's own producers did not.

Every flag has a TRACEGEN_* environment fallback so Kubernetes Jobs can be
parameterized without rebuilding the image.
"""

import argparse
import json
import os
import random
import socket
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import templates  # noqa: E402


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def env_default(name, fallback):
    return os.environ.get("TRACEGEN_%s" % name, fallback)


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--endpoint", default=env_default("ENDPOINT", "http://perf-sentinel-daemon.observability.svc.cluster.local:14318"))
    p.add_argument("--protocol", default=env_default("PROTOCOL", "http-pb"),
                   choices=["http-pb", "grpc", "ndjson-socket", "dump-native", "dump-jaeger", "dump-zipkin"])
    p.add_argument("--compression", default=env_default("COMPRESSION", "none"),
                   choices=["none", "gzip", "deflate"],
                   help="http-pb and grpc only: compress the export the way a real exporter does. gRPC deflate is unreachable from the Collector's exporter (gzip/snappy/zstd only), so this client is the lab's only way to exercise it")
    p.add_argument("--services", type=int, default=int(env_default("SERVICES", "50")))
    p.add_argument("--service-prefix", default=env_default("SERVICE_PREFIX", "synth"))
    p.add_argument("--run-nonce", default=env_default("RUN_NONCE", ""),
                   help="suffix making service names unique per run (default: derived from time; set explicitly for reproducible names)")
    p.add_argument("--tps", type=int, default=int(env_default("TPS", "25")), help="traces per second")
    p.add_argument("--duration", type=int, default=int(env_default("DURATION", "60")), help="seconds (ignored when --ramp or dump mode)")
    p.add_argument("--ramp", default=env_default("RAMP", ""), help='steps "tps:seconds,tps:seconds,..." overriding --tps/--duration')
    p.add_argument("--mix", default=env_default("MIX", "n_plus_one:30,redundant:10,chatty:10,fanout:5,slow:5,clean:40"))
    p.add_argument("--shape", default=env_default("SHAPE", ""), choices=["", "max_events", "deep_chain", "wide_fanout", "dup_trace_ids", "huge_sql"],
                   help="adversarial single-trait mode overriding --mix")
    p.add_argument("--spans-per-trace", type=int, default=int(env_default("SPANS_PER_TRACE", "6")))
    p.add_argument("--n-plus-one-count", type=int, default=int(env_default("N_PLUS_ONE_COUNT", "8")))
    p.add_argument("--fanout-width", type=int, default=int(env_default("FANOUT_WIDTH", "25")))
    p.add_argument("--chain-depth", type=int, default=int(env_default("CHAIN_DEPTH", "400")))
    p.add_argument("--sql-bytes", type=int, default=int(env_default("SQL_BYTES", "70000")))
    p.add_argument("--events-per-trace", type=int, default=int(env_default("EVENTS_PER_TRACE", "1500")))
    p.add_argument("--dup-gap-s", type=int, default=int(env_default("DUP_GAP_S", "7")),
                   help="dup_trace_ids: seconds between the two identical emissions")
    p.add_argument("--batch-traces", type=int, default=int(env_default("BATCH_TRACES", "50")), help="traces per export request")
    p.add_argument("--payload-bank", type=int, default=int(env_default("PAYLOAD_BANK", "0")),
                   help="http-pb only: pre-serialize N distinct request payloads and send them round-robin, lifting the generator ceiling far above what per-second Python serialization allows. Trace ids repeat across the run (size the bank above tps x daemon TTL)")
    p.add_argument("--resource-blocks", type=int, default=int(env_default("RESOURCE_BLOCKS", "0")),
                   help="cap distinct ResourceSpans per request (0 = one per service)")
    p.add_argument("--seed", type=int, default=int(env_default("SEED", "42")))
    p.add_argument("--traces", type=int, default=int(env_default("TRACES", "1000")), help="dump modes and shape modes: total traces")
    p.add_argument("--shards", type=int, default=int(env_default("SHARDS", "1")), help="dump modes: number of output files")
    p.add_argument("--out", default=env_default("OUT", "/tmp/tracegen"), help="dump modes: output directory")
    p.add_argument("--report-file", default=env_default("REPORT_FILE", ""), help="write the final JSON report here (default stdout)")
    return p.parse_args()


def parse_mix(spec):
    weights = []
    for part in spec.split(","):
        name, _, w = part.strip().partition(":")
        if name not in templates.PATTERNS:
            sys.exit("unknown pattern in --mix: %s" % name)
        weights.append((name, int(w or "1")))
    if not weights or sum(w for _, w in weights) == 0:
        sys.exit("--mix must carry at least one positive weight")
    return weights


def parse_ramp(spec):
    steps = []
    for part in spec.split(","):
        tps, _, secs = part.strip().partition(":")
        steps.append((int(tps), int(secs)))
    return steps


# --------------------------------------------------------------------------
# Trace building
# --------------------------------------------------------------------------

BASE_NS = 1_749_297_600_000_000_000


class Generator:
    def __init__(self, args):
        self.rng = random.Random(args.seed)
        self.args = args
        nonce = args.run_nonce or format(int(time.time()) % 0xFFFFF, "05x")
        self.services = ["%s-%s-%04d" % (args.service_prefix, nonce, i) for i in range(max(1, args.services))]
        self.mix = parse_mix(args.mix)
        self.mix_total = sum(w for _, w in self.mix)
        self.trace_seq = 0
        self.planted = {name: 0 for name in templates.PATTERNS}
        for shape in templates.SHAPES:
            self.planted[shape] = 0
        self.spans_sent = 0
        self.spans_io = 0

    def pick_pattern(self):
        draw = self.rng.randint(1, self.mix_total)
        acc = 0
        for name, w in self.mix:
            acc += w
            if draw <= acc:
                return name
        return self.mix[-1][0]

    def next_trace(self, shape=None):
        """Build one trace: (trace_num, service, spans)."""
        self.trace_seq += 1
        service = self.services[(self.trace_seq - 1) % len(self.services)]
        ctx = {
            "rng": self.rng,
            "base_ns": BASE_NS + self.trace_seq * 1_000_000,
            "spans_per_trace": self.args.spans_per_trace,
            "n_plus_one_count": self.args.n_plus_one_count,
            "fanout_width": self.args.fanout_width,
            "chain_depth": self.args.chain_depth,
            "sql_bytes": self.args.sql_bytes,
            "events_per_trace": self.args.events_per_trace,
        }
        if shape:
            spans = templates.SHAPES[shape](ctx)
            self.planted[shape] += 1
        else:
            pattern = self.pick_pattern()
            spans = templates.PATTERNS[pattern](ctx)
            self.planted[pattern] += 1
        self.spans_sent += len(spans)
        self.spans_io += sum(1 for s in spans if "db.statement" in s["attrs"] or "http.url" in s["attrs"])
        return self.trace_seq, service, spans

    def report(self, requests):
        return {
            "requests": requests,
            "traces": self.trace_seq,
            "spans": self.spans_sent,
            "spans_io": self.spans_io,
            "services": len(self.services),
            "planted": {k: v for k, v in self.planted.items() if v},
        }


# --------------------------------------------------------------------------
# Encoders
# --------------------------------------------------------------------------


def trace_id_bytes(num):
    return num.to_bytes(16, "big")


def span_id_bytes(trace_num, sid):
    return ((trace_num << 20) | sid).to_bytes(8, "big")


def iso_ts(ns):
    dt = datetime.fromtimestamp(ns / 1e9, tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (ns // 1_000_000 % 1000)


def to_otlp_request(batch, resource_blocks=0):
    """batch: list of (trace_num, service, spans). Groups spans per service
    into ResourceSpans, like a collector batching a fleet."""
    from opentelemetry.proto.collector.trace.v1 import trace_service_pb2 as svc
    from opentelemetry.proto.common.v1 import common_pb2 as common
    from opentelemetry.proto.resource.v1 import resource_pb2 as resource
    from opentelemetry.proto.trace.v1 import trace_pb2 as trace

    def kv(key, val):
        return common.KeyValue(key=key, value=common.AnyValue(string_value=val))

    kinds = {"server": trace.Span.SPAN_KIND_SERVER, "client": trace.Span.SPAN_KIND_CLIENT}
    by_service = {}
    for trace_num, service, spans in batch:
        by_service.setdefault(service, []).append((trace_num, spans))
    blocks = []
    for service, traces in by_service.items():
        pb_spans = []
        for trace_num, spans in traces:
            for s in spans:
                pb_spans.append(trace.Span(
                    trace_id=trace_id_bytes(trace_num),
                    span_id=span_id_bytes(trace_num, s["sid"]),
                    parent_span_id=span_id_bytes(trace_num, s["parent"]) if s["parent"] else b"",
                    name=s["name"],
                    kind=kinds[s["kind"]],
                    start_time_unix_nano=s["start_ns"],
                    end_time_unix_nano=s["end_ns"],
                    attributes=[kv(k, v) for k, v in s["attrs"].items()],
                ))
        blocks.append(trace.ResourceSpans(
            resource=resource.Resource(attributes=[
                kv("service.name", service),
                kv("cloud.region", "eu-west-3"),
            ]),
            scope_spans=[trace.ScopeSpans(spans=pb_spans)],
        ))
    if resource_blocks and len(blocks) > resource_blocks:
        merged = blocks[: resource_blocks - 1]
        rest = trace.ResourceSpans(
            resource=blocks[resource_blocks - 1].resource,
            scope_spans=[trace.ScopeSpans(spans=[s for b in blocks[resource_blocks - 1:] for ss in b.scope_spans for s in ss.spans])],
        )
        merged.append(rest)
        blocks = merged
    return svc.ExportTraceServiceRequest(resource_spans=blocks)


def io_kind(span):
    if "db.statement" in span["attrs"]:
        return "sql"
    if "http.url" in span["attrs"]:
        return "http_out"
    return None


def to_native_events(batch):
    """Native SpanEvent JSON: only I/O spans, the format `analyze --input`
    and the daemon NDJSON socket consume."""
    events = []
    for trace_num, service, spans in batch:
        root = next((s for s in spans if s["parent"] is None), spans[0])
        endpoint = root["attrs"].get("http.route", "GET /api/unknown")
        for s in spans:
            kind = io_kind(s)
            if kind is None:
                continue
            if kind == "sql":
                operation = s["attrs"]["db.statement"].split(None, 1)[0].upper()
                target = s["attrs"]["db.statement"]
            else:
                operation = s["attrs"].get("http.method", "GET")
                target = s["attrs"]["http.url"]
            events.append({
                "timestamp": iso_ts(s["start_ns"]),
                "trace_id": "t%032x" % trace_num,
                "span_id": "s%016x" % ((trace_num << 20) | s["sid"]),
                "parent_span_id": ("s%016x" % ((trace_num << 20) | s["parent"])) if s["parent"] else None,
                "service": service,
                "cloud_region": "eu-west-3",
                "type": kind,
                "operation": operation,
                "target": target,
                "duration_us": (s["end_ns"] - s["start_ns"]) // 1000,
                "source": {"endpoint": endpoint, "method": "Handler::handle"},
            })
    return events


def to_jaeger(batch):
    data = []
    for trace_num, service, spans in batch:
        jspans = []
        for s in spans:
            tags = [{"key": k, "value": v} for k, v in s["attrs"].items()]
            jspan = {
                "spanID": "s%016x" % ((trace_num << 20) | s["sid"]),
                "operationName": s["name"],
                "references": [],
                "startTime": s["start_ns"] // 1000,
                "duration": (s["end_ns"] - s["start_ns"]) // 1000,
                "processID": "p1",
                "tags": tags,
            }
            if s["parent"]:
                jspan["references"] = [{"refType": "CHILD_OF", "spanID": "s%016x" % ((trace_num << 20) | s["parent"])}]
            jspans.append(jspan)
        data.append({
            "traceID": "t%032x" % trace_num,
            "spans": jspans,
            "processes": {"p1": {"serviceName": service}},
        })
    return {"data": data}


def to_zipkin(batch):
    out = []
    for trace_num, service, spans in batch:
        for s in spans:
            z = {
                "traceId": "t%032x" % trace_num,
                "id": "s%016x" % ((trace_num << 20) | s["sid"]),
                "name": s["name"],
                "timestamp": s["start_ns"] // 1000,
                "duration": (s["end_ns"] - s["start_ns"]) // 1000,
                "localEndpoint": {"serviceName": service},
                "tags": dict(s["attrs"]),
            }
            if s["parent"]:
                z["parentId"] = "s%016x" % ((trace_num << 20) | s["parent"])
            out.append(z)
    return out


# --------------------------------------------------------------------------
# Senders
# --------------------------------------------------------------------------


class HttpPbSender:
    """Persistent connection (keep-alive) with bounded retries: a load
    generator that dies on the first transient refusal measures its own
    fragility, not the daemon's limit."""

    def __init__(self, endpoint, compression="none"):
        import urllib.parse

        u = urllib.parse.urlparse(endpoint)
        self.host = u.hostname
        self.port = u.port or 80
        self.conn = None
        self.retries_used = 0
        self.compression = compression

    def _connect(self):
        import http.client

        self.conn = http.client.HTTPConnection(self.host, self.port, timeout=30)

    def send(self, batch, resource_blocks):
        self.send_raw(to_otlp_request(batch, resource_blocks).SerializeToString())

    def encode(self, body):
        """Compress once. The payload bank encodes at build time so a
        compressed run does not pay the codec on every request and keeps
        measuring the daemon rather than this generator."""
        if self.compression == "gzip":
            import gzip

            return gzip.compress(body)
        if self.compression == "deflate":
            import zlib

            # zlib format (RFC 1950), what tower-http and tonic decode for
            # deflate. Raw DEFLATE would be refused by both.
            return zlib.compress(body)
        return body

    def send_raw(self, body, encoded=False):
        if not encoded:
            body = self.encode(body)
        headers = {"Content-Type": "application/x-protobuf"}
        if self.compression != "none":
            headers["Content-Encoding"] = self.compression
        last = None
        for attempt in range(5):
            try:
                if self.conn is None:
                    self._connect()
                self.conn.request("POST", "/v1/traces", body=body, headers=headers)
                resp = self.conn.getresponse()
                resp.read()
                if resp.status >= 300:
                    raise RuntimeError("OTLP HTTP status %d" % resp.status)
                return
            except (OSError, RuntimeError) as e:
                last = e
                self.conn = None
                self.retries_used += 1
                time.sleep(0.5 * (attempt + 1))
        raise RuntimeError("send failed after retries: %s" % last)


class GrpcSender:
    def __init__(self, endpoint, compression="none"):
        import grpc
        from opentelemetry.proto.collector.trace.v1 import trace_service_pb2_grpc as svc_grpc

        target = endpoint.replace("http://", "").replace("https://", "")
        # grpc sets the `grpc-encoding` header from this, exactly like a real
        # exporter: the listener has to advertise the encoding via
        # accept_compressed or it answers Unimplemented.
        codec = {"none": grpc.Compression.NoCompression,
                 "gzip": grpc.Compression.Gzip,
                 "deflate": grpc.Compression.Deflate}[compression]
        self.channel = grpc.insecure_channel(target, compression=codec)
        self.stub = svc_grpc.TraceServiceStub(self.channel)

    def send(self, batch, resource_blocks):
        self.stub.Export(to_otlp_request(batch, resource_blocks), timeout=30)


class NdjsonSocketSender:
    """One NDJSON line per batch: a JSON array of native SpanEvents."""

    def __init__(self, endpoint):
        self.path = endpoint
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        # Retry: as a sidecar this can start before the daemon listens.
        for attempt in range(60):
            try:
                self.sock.connect(self.path)
                break
            except OSError:
                if attempt == 59:
                    raise
                time.sleep(2)

    def send(self, batch, _resource_blocks):
        line = json.dumps(to_native_events(batch), separators=(",", ":")) + "\n"
        self.sock.sendall(line.encode())


def make_sender(args):
    if args.protocol == "http-pb":
        return HttpPbSender(args.endpoint, args.compression)
    if args.protocol == "grpc":
        return GrpcSender(args.endpoint, args.compression)
    if args.protocol == "ndjson-socket":
        return NdjsonSocketSender(args.endpoint)
    raise AssertionError("not a live protocol: %s" % args.protocol)


# --------------------------------------------------------------------------
# Run modes
# --------------------------------------------------------------------------


def run_dump(args, gen):
    os.makedirs(args.out, exist_ok=True)
    fmt = args.protocol.split("-", 1)[1]
    per_shard = max(1, args.traces // max(1, args.shards))
    requests = 0
    for shard in range(args.shards):
        batch = [gen.next_trace(args.shape or None) for _ in range(per_shard)]
        if fmt == "native":
            payload = to_native_events(batch)
        elif fmt == "jaeger":
            payload = to_jaeger(batch)
        else:
            payload = to_zipkin(batch)
        path = os.path.join(args.out, "shard-%02d.%s.json" % (shard, fmt))
        with open(path, "w") as f:
            json.dump(payload, f, separators=(",", ":"))
        requests += 1
        print("wrote %s (%d traces)" % (path, per_shard), file=sys.stderr)
    return requests


def run_shape_live(args, gen, sender):
    """Low-rate adversarial shapes, including the dup_trace_ids replay."""
    requests = 0
    if args.shape == "dup_trace_ids":
        batch = [gen.next_trace() for _ in range(args.traces)]
        for chunk in chunked(batch, args.batch_traces):
            sender.send(chunk, args.resource_blocks)
            requests += 1
        time.sleep(args.dup_gap_s)
        for chunk in chunked(batch, args.batch_traces):
            sender.send(chunk, args.resource_blocks)
            requests += 1
        return requests
    for _ in range(args.traces):
        sender.send([gen.next_trace(args.shape)], args.resource_blocks)
        requests += 1
    return requests


def chunked(items, n):
    for i in range(0, len(items), n):
        yield items[i : i + n]


def run_steady(args, gen, sender, steps):
    """Rate-controlled emission. Prints one marker line per ramp step so
    samplers can align their windows with the load profile."""
    requests = 0
    bank = None
    if args.payload_bank > 0:
        if args.protocol != "http-pb":
            sys.exit("--payload-bank only supports --protocol http-pb")
        # Pre-serialize the bank once: runtime cost per request becomes a
        # socket write, so the generator can outrun the daemon.
        bank = []
        for _ in range(args.payload_bank):
            chunk = [gen.next_trace() for _ in range(args.batch_traces)]
            bank.append(sender.encode(to_otlp_request(chunk, args.resource_blocks).SerializeToString()))
        print("PAYLOAD_BANK ready entries=%d traces_each=%d" % (len(bank), args.batch_traces), flush=True)
    bank_idx = 0
    for tps, seconds in steps:
        print("RAMP_STEP tps=%d seconds=%d t=%d" % (tps, seconds, int(time.time())), flush=True)
        for _ in range(seconds):
            second_start = time.monotonic()
            if bank is not None:
                sends = max(1, tps // args.batch_traces)
                for _ in range(sends):
                    sender.send_raw(bank[bank_idx % len(bank)], encoded=True)
                    bank_idx += 1
                    requests += 1
                # Bank replays re-emit the same trace ids: account spans
                # without regenerating.
                gen.trace_seq += sends * args.batch_traces
            else:
                batch = [gen.next_trace() for _ in range(tps)]
                for chunk in chunked(batch, args.batch_traces):
                    sender.send(chunk, args.resource_blocks)
                    requests += 1
            elapsed = time.monotonic() - second_start
            if elapsed > 1.2:
                print("LAG behind by %.2fs at tps=%d" % (elapsed - 1.0, tps), flush=True)
            time.sleep(max(0.0, 1.0 - elapsed))
    return requests


def main():
    args = parse_args()
    gen = Generator(args)
    if args.protocol.startswith("dump-"):
        requests = run_dump(args, gen)
    else:
        sender = make_sender(args)
        if args.shape:
            requests = run_shape_live(args, gen, sender)
        else:
            steps = parse_ramp(args.ramp) if args.ramp else [(args.tps, args.duration)]
            requests = run_steady(args, gen, sender, steps)
    report = gen.report(requests)
    line = json.dumps(report)
    if args.report_file:
        with open(args.report_file, "w") as f:
            f.write(line + "\n")
    print(line, flush=True)


if __name__ == "__main__":
    main()
