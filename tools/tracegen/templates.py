"""Span-shape builders for tracegen.

Every builder returns a list of abstract span dicts for ONE trace:
  {"sid": int, "parent": int|None, "name": str, "kind": "server"|"client",
   "start_ns": int, "end_ns": int, "attrs": {str: str}}
Span ids are small integers local to the trace; encoders combine them with
the trace id to mint wire-format ids. Every retained span carries real I/O
semantics (db.statement or http.url) so perf-sentinel's filter keeps it and
detect + score do real work, exactly like the daemon-analysis-shedding
fixture this module generalizes.
"""

SQL_TABLES = [
    "orders",
    "order_item",
    "users",
    "payments",
    "inventory",
    "audit_log",
    "sessions",
    "products",
    "shipments",
    "carts",
    "coupons",
    "reviews",
]

HTTP_ROUTES = [
    "http://user-svc:5000/api/users",
    "http://product-svc:5000/api/products",
    "http://stock-svc:5000/api/stock",
    "http://billing-svc:5000/api/invoices",
    "http://auth-svc:5000/api/tokens",
    "http://geo-svc:5000/api/locations",
    "http://search-svc:5000/api/search",
    "http://media-svc:5000/api/assets",
]

SERVER_ROUTES = [
    "/api/orders/{id}/submit",
    "/api/orders/{id}",
    "/api/users/{id}/profile",
    "/api/payments",
    "/api/catalog/search",
    "/api/carts/{id}/checkout",
]

MS = 1_000_000  # ns per ms


def _root(ctx, route, duration_ms=120):
    return {
        "sid": 1,
        "parent": None,
        "name": "GET %s" % route,
        "kind": "server",
        "start_ns": ctx["base_ns"],
        "end_ns": ctx["base_ns"] + duration_ms * MS,
        "attrs": {"http.route": route, "http.url": "http://gw%s" % route},
    }


def _sql(ctx, sid, parent, offset_ms, statement, duration_ms=2):
    start = ctx["base_ns"] + offset_ms * MS
    return {
        "sid": sid,
        "parent": parent,
        "name": "db-query",
        "kind": "client",
        "start_ns": start,
        "end_ns": start + duration_ms * MS,
        "attrs": {"db.system": "postgresql", "db.statement": statement},
    }


def _http(ctx, sid, parent, offset_ms, url, duration_ms=8):
    start = ctx["base_ns"] + offset_ms * MS
    return {
        "sid": sid,
        "parent": parent,
        "name": "http-call",
        "kind": "client",
        "start_ns": start,
        "end_ns": start + duration_ms * MS,
        "attrs": {"http.url": url, "http.method": "GET", "http.status_code": "200"},
    }


def n_plus_one(ctx):
    rng = ctx["rng"]
    route = rng.choice(SERVER_ROUTES)
    table = rng.choice(SQL_TABLES)
    count = ctx.get("n_plus_one_count", 8)
    spans = [_root(ctx, route)]
    for i in range(count):
        stmt = "SELECT * FROM %s WHERE parent_id = %d" % (table, rng.randint(1000, 99999))
        spans.append(_sql(ctx, i + 2, 1, 2 + i * 4, stmt))
    return spans


def redundant(ctx):
    rng = ctx["rng"]
    route = rng.choice(SERVER_ROUTES)
    table = rng.choice(SQL_TABLES)
    stmt = "SELECT * FROM %s WHERE id = %d" % (table, rng.randint(1000, 99999))
    spans = [_root(ctx, route)]
    for i in range(5):
        spans.append(_sql(ctx, i + 2, 1, 2 + i * 3, stmt))
    return spans


def chatty(ctx):
    rng = ctx["rng"]
    route = rng.choice(SERVER_ROUTES)
    spans = [_root(ctx, route, duration_ms=200)]
    for i in range(16):
        base = HTTP_ROUTES[i % len(HTTP_ROUTES)]
        url = "%s/%d" % (base, rng.randint(100, 999))
        spans.append(_http(ctx, i + 2, 1, 2 + i * 3, url))
    return spans


def fanout(ctx):
    rng = ctx["rng"]
    width = ctx.get("fanout_width", 25)
    route = rng.choice(SERVER_ROUTES)
    base = rng.choice(HTTP_ROUTES)
    spans = [_root(ctx, route, duration_ms=150)]
    for i in range(width):
        spans.append(_http(ctx, i + 2, 1, 3, "%s/%d" % (base, 200 + i), duration_ms=6))
    return spans


def slow(ctx):
    rng = ctx["rng"]
    route = rng.choice(SERVER_ROUTES)
    table = rng.choice(SQL_TABLES)
    stmt = "SELECT * FROM %s ORDER BY created_at DESC LIMIT 50" % table
    spans = [_root(ctx, route, duration_ms=3000)]
    for i in range(3):
        spans.append(_sql(ctx, i + 2, 1, 5 + i * 12, stmt, duration_ms=850))
    return spans


def clean(ctx):
    rng = ctx["rng"]
    route = rng.choice(SERVER_ROUTES)
    count = max(2, ctx.get("spans_per_trace", 6))
    spans = [_root(ctx, route)]
    for i in range(count):
        if i % 3 == 2:
            base = rng.choice(HTTP_ROUTES)
            spans.append(_http(ctx, i + 2, 1, 2 + i * 4, "%s/%d" % (base, 300 + i)))
        else:
            table = SQL_TABLES[(i + rng.randint(0, 2)) % len(SQL_TABLES)]
            stmt = "SELECT id, status FROM %s WHERE id = %d AND tenant = 'a%d'" % (
                table,
                rng.randint(1000, 99999),
                i,
            )
            spans.append(_sql(ctx, i + 2, 1, 2 + i * 4, stmt))
    return spans


# --- limit shapes (one adversarial trait per trace) -----------------------


def shape_max_events(ctx):
    """One trace far above max_events_per_trace (default daemon cap 1000)."""
    count = ctx.get("events_per_trace", 1500)
    table = ctx["rng"].choice(SQL_TABLES)
    spans = [_root(ctx, "/api/bulk", duration_ms=5000)]
    for i in range(count):
        stmt = "SELECT * FROM %s WHERE parent_id = %d" % (table, i)
        spans.append(_sql(ctx, i + 2, 1, 1 + i, stmt, duration_ms=1))
    return spans


def shape_deep_chain(ctx):
    """A parent chain far deeper than the OTLP code-attr walk (8) and the
    explain tree depth guard (256)."""
    depth = ctx.get("chain_depth", 400)
    spans = [_root(ctx, "/api/chain")]
    for i in range(depth):
        url = "http://hop-svc:5000/api/hop/%d" % i
        span = _http(ctx, i + 2, i + 1, 1 + i, url, duration_ms=2)
        spans.append(span)
    return spans


def shape_wide_fanout(ctx):
    ctx = dict(ctx)
    ctx["fanout_width"] = ctx.get("fanout_width", 1200)
    return fanout(ctx)


def shape_huge_sql(ctx):
    """db.statement padded past perf-sentinel's 64 KiB target cap."""
    pad_bytes = ctx.get("sql_bytes", 70_000)
    filler = " OR note = '%s'" % ("x" * pad_bytes)
    stmt = "SELECT * FROM audit_log WHERE id = 1%s" % filler
    return [_root(ctx, "/api/audit"), _sql(ctx, 2, 1, 2, stmt, duration_ms=4)]


PATTERNS = {
    "n_plus_one": n_plus_one,
    "redundant": redundant,
    "chatty": chatty,
    "fanout": fanout,
    "slow": slow,
    "clean": clean,
}

SHAPES = {
    "max_events": shape_max_events,
    "deep_chain": shape_deep_chain,
    "wide_fanout": shape_wide_fanout,
    "huge_sql": shape_huge_sql,
}
