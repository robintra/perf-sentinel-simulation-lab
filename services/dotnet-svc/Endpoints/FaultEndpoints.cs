using System.Diagnostics;
using System.Globalization;
using DotnetSvc.Data;
using Microsoft.EntityFrameworkCore;

namespace DotnetSvc.Endpoints;

/// <summary>
/// The 10 perf-sentinel anti-pattern endpoints. All POST under /api/fault.
/// JSON response shape: { antiPattern, service, durationMs, details, timestamp }
/// matches the multistack contract documented in docs/MULTISTACK.md.
///
/// SQL faults go through EF Core 10. The OTel EF Core instrumentation
/// emits an ActivitySource named `OpenTelemetry.Instrumentation.EntityFrameworkCore`
/// on every DbContext command — this is the ORM marker the strict
/// perf-sentinel classifier consumes to keep the n+1_sql verdict
/// (equivalent of Java's `io.opentelemetry.hibernate-6.0`).
///
/// HTTP faults go through a named HttpClient ("self") whose handler
/// is wrapped by OpenTelemetry.Instrumentation.Http — produces CLIENT
/// spans the daemon needs for the HTTP-side classifiers.
/// </summary>
internal static class FaultEndpoints
{
    private const string Service = "dotnet-svc";
    private static readonly string[] Channels = { "email", "sms", "push", "webhook", "slack", "teams" };

    public static IEndpointRouteBuilder MapFaultEndpoints(this IEndpointRouteBuilder app)
    {
        var fault = app.MapGroup("/api/fault");

        fault.MapPost("/n-plus-one-sql", NPlusOneSql);
        fault.MapPost("/n-plus-one-http", NPlusOneHttp);
        fault.MapPost("/redundant-sql", RedundantSql);
        fault.MapPost("/redundant-http", RedundantHttp);
        fault.MapPost("/slow-sql", SlowSql);
        fault.MapPost("/slow-http", SlowHttp);
        fault.MapPost("/fanout", Fanout);
        fault.MapPost("/chatty", Chatty);
        fault.MapPost("/serialized", Serialized);
        fault.MapPost("/pool-saturation", PoolSaturation);

        return app;
    }

    // === plumbing =============================================================

    private static object Envelope(string antiPattern, long durationMs, IDictionary<string, object?> details)
    {
        return new
        {
            antiPattern,
            service = Service,
            durationMs,
            details,
            timestamp = DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture),
        };
    }

    private static async Task<IResult> Timed(
            string antiPattern,
            IDictionary<string, object?> input,
            Func<Task<IDictionary<string, object?>>> body)
    {
        long start = Stopwatch.GetTimestamp();
        var details = new Dictionary<string, object?>(input);
        var bodyDetails = await body();
        foreach (var kv in bodyDetails)
        {
            details[kv.Key] = kv.Value;
        }
        long elapsedMs = (long)Stopwatch.GetElapsedTime(start).TotalMilliseconds;
        return Results.Json(Envelope(antiPattern, elapsedMs, details));
    }

    private static int StatusOk(HttpResponseMessage r) => r.IsSuccessStatusCode ? 1 : 0;

    // === SQL anti-patterns =====================================================

    private static Task<IResult> NPlusOneSql(int? items, AppDbContext db)
        => Timed("n_plus_one_sql", new Dictionary<string, object?> { ["items"] = items ?? 15 }, async () =>
        {
            int n = items ?? 15;
            int total = 0;
            // EF Core LINQ — one parameterised query per loop iteration.
            // The OTel EF Core ActivitySource attaches the
            // `OpenTelemetry.Instrumentation.EntityFrameworkCore` scope
            // to each command span, which the perf-sentinel strict
            // classifier needs to keep the n+1 verdict (otherwise the
            // sanitiser collapses N executes to one template and the
            // verdict falls back to redundant_sql — see Gap #20).
            for (int orderId = 1; orderId <= n; orderId++)
            {
                int id = orderId;
                total += await db.OrderItems.Where(oi => oi.OrderId == id).CountAsync();
            }
            return new Dictionary<string, object?>
            {
                ["orders_touched"] = n,
                ["items_total"] = total,
            };
        });

    private static Task<IResult> RedundantSql(int? repeats, AppDbContext db)
        => Timed("redundant_sql", new Dictionary<string, object?> { ["repeats"] = repeats ?? 10 }, async () =>
        {
            int n = repeats ?? 10;
            int total = 0;
            for (int i = 0; i < n; i++)
            {
                total += await db.Payments.Where(p => p.CustomerId == 1L).CountAsync();
            }
            return new Dictionary<string, object?>
            {
                ["queries_made"] = n,
                ["rows_seen"] = total,
            };
        });

    private static Task<IResult> SlowSql(long? delayMs, int? repeats, AppDbContext db)
        => Timed(
                "slow_sql",
                new Dictionary<string, object?> { ["delayMs"] = delayMs ?? 600L, ["repeats"] = repeats ?? 6 },
                async () =>
        {
            long ms = delayMs ?? 600L;
            int n = repeats ?? 6;
            double seconds = ms / 1000.0;
            int executed = 0;
            for (int i = 0; i < n; i++)
            {
                // ExecuteSqlRawAsync with literal interpolation. Locale-pinned
                // to invariant so French/German locales don't emit `0,6`
                // for `0.6`. Lab-intentional — the slow_sql detector keys
                // off span duration, not query text shape.
                string sql = string.Format(
                        CultureInfo.InvariantCulture,
                        "SELECT pg_sleep({0}), * FROM dotnet.orders ORDER BY id OFFSET {1} LIMIT 1",
                        seconds, i);
                await db.Database.ExecuteSqlRawAsync(sql);
                executed++;
            }
            return new Dictionary<string, object?>
            {
                ["queries_executed"] = executed,
                ["delay_ms"] = ms,
            };
        });

    private static Task<IResult> PoolSaturation(int? concurrency, IServiceProvider sp)
        => Timed(
                "pool_saturation",
                new Dictionary<string, object?> { ["concurrency"] = concurrency ?? 20 },
                async () =>
        {
            int n = concurrency ?? 20;
            // Each worker spins up its own AsyncScope so the underlying
            // DbContext (and its Npgsql connection acquisition) is
            // independent. Npgsql pool is capped at 10 in the connection
            // string, so concurrency 20 saturates with ~10 waiting.
            var tasks = new Task<int>[n];
            for (int i = 0; i < n; i++)
            {
                tasks[i] = Task.Run(async () =>
                {
                    await using var scope = sp.CreateAsyncScope();
                    var ctx = scope.ServiceProvider.GetRequiredService<AppDbContext>();
                    await ctx.Database.ExecuteSqlRawAsync("SELECT pg_sleep(0.4)");
                    return 1;
                });
            }
            int[] results = await Task.WhenAll(tasks);
            return new Dictionary<string, object?>
            {
                ["tasks_launched"] = n,
                ["tasks_completed"] = results.Sum(),
            };
        });

    // === HTTP anti-patterns ====================================================

    private static Task<IResult> NPlusOneHttp(int? recipients, IHttpClientFactory factory)
        => Timed(
                "n_plus_one_http",
                new Dictionary<string, object?> { ["recipients"] = recipients ?? 10 },
                async () =>
        {
            int n = recipients ?? 10;
            var http = factory.CreateClient("self");
            int ok = 0;
            for (int i = 0; i < n; i++)
            {
                using var r = await http.GetAsync($"/api/external/mock?delayMs=0&seq={i}&op=0");
                ok += StatusOk(r);
            }
            return new Dictionary<string, object?>
            {
                ["calls_made"] = n,
                ["calls_ok"] = ok,
            };
        });

    private static Task<IResult> RedundantHttp(int? repeats, IHttpClientFactory factory)
        => Timed(
                "redundant_http",
                new Dictionary<string, object?> { ["repeats"] = repeats ?? 10 },
                async () =>
        {
            int n = repeats ?? 10;
            var http = factory.CreateClient("self");
            int ok = 0;
            for (int i = 0; i < n; i++)
            {
                using var r = await http.GetAsync("/api/payments/history?customerId=1&limit=10");
                ok += StatusOk(r);
            }
            return new Dictionary<string, object?>
            {
                ["calls_made"] = n,
                ["calls_ok"] = ok,
            };
        });

    private static Task<IResult> SlowHttp(long? delayMs, int? repeats, IHttpClientFactory factory)
        => Timed(
                "slow_http",
                new Dictionary<string, object?> { ["delayMs"] = delayMs ?? 600L, ["repeats"] = repeats ?? 6 },
                async () =>
        {
            long ms = delayMs ?? 600L;
            int n = repeats ?? 6;
            var http = factory.CreateClient("self");
            int ok = 0;
            for (int i = 0; i < n; i++)
            {
                using var r = await http.GetAsync($"/api/external/mock?delayMs={ms}&seq={i}&op=0");
                ok += StatusOk(r);
            }
            return new Dictionary<string, object?>
            {
                ["calls_made"] = n,
                ["calls_ok"] = ok,
                ["delay_ms"] = ms,
            };
        });

    private static Task<IResult> Fanout(int? width, IHttpClientFactory factory)
        => Timed(
                "excessive_fanout",
                new Dictionary<string, object?> { ["width"] = width ?? 40 },
                async () =>
        {
            int n = width ?? 40;
            var http = factory.CreateClient("self");
            var tasks = new Task<int>[n];
            for (int i = 0; i < n; i++)
            {
                int seq = i;
                tasks[i] = Task.Run(async () =>
                {
                    using var r = await http.GetAsync($"/api/external/mock?delayMs=10&seq={seq}&op=0");
                    return StatusOk(r);
                });
            }
            int[] results = await Task.WhenAll(tasks);
            return new Dictionary<string, object?>
            {
                ["children_launched"] = n,
                ["children_ok"] = results.Sum(),
            };
        });

    private static Task<IResult> Chatty(int? calls, IHttpClientFactory factory)
        => Timed(
                "chatty_service",
                new Dictionary<string, object?> { ["calls"] = calls ?? 30 },
                async () =>
        {
            int n = calls ?? 30;
            var http = factory.CreateClient("self");
            int ok = 0;
            for (int i = 0; i < n; i++)
            {
                using var r = await http.GetAsync($"/api/external/mock?delayMs=5&seq={i}&op={i % 7}");
                ok += StatusOk(r);
            }
            return new Dictionary<string, object?>
            {
                ["calls_made"] = n,
                ["calls_ok"] = ok,
            };
        });

    private static Task<IResult> Serialized(int? steps, IHttpClientFactory factory)
        => Timed(
                "serialized_calls",
                new Dictionary<string, object?> { ["steps"] = steps ?? 6 },
                async () =>
        {
            int n = Math.Min(steps ?? 6, Channels.Length);
            var http = factory.CreateClient("self");
            long startNs = Stopwatch.GetTimestamp();
            int ok = 0;
            for (int i = 0; i < n; i++)
            {
                using var r = await http.GetAsync($"/api/dispatch/{Channels[i]}?delayMs=80");
                ok += StatusOk(r);
            }
            long wallClockMs = (long)Stopwatch.GetElapsedTime(startNs).TotalMilliseconds;
            return new Dictionary<string, object?>
            {
                ["steps_ok"] = ok,
                ["wall_clock_ms"] = wallClockMs,
            };
        });
}
