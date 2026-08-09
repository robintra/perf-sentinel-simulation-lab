using System.Diagnostics;
using System.Globalization;
using DotnetSvc.Data;
using DotnetSvc.Messaging;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Primitives;

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
    private static readonly ActivitySource HttpBoundary = new("DotnetSvc.HttpBoundary");

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
        fault.MapPost("/n-plus-one-messaging", NPlusOneMessaging);
        fault.MapPost("/slow-messaging", SlowMessaging);

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

    private static bool TryQueryInt(HttpRequest request, string name, int fallback, out int value)
    {
        StringValues raw = request.Query[name];
        if (raw.Count == 0
            && !request.Query.Keys.Any(key => key.StartsWith($"{name}[", StringComparison.Ordinal)))
        {
            value = fallback;
            return true;
        }
        value = 0;
        return raw.Count == 1
               && int.TryParse(raw[0], NumberStyles.None, CultureInfo.InvariantCulture, out value);
    }

    private static bool IsRabbitMq(HttpRequest request)
    {
        StringValues broker = request.Query["broker"];
        return !request.Query.Keys.Any(key => key.StartsWith("broker[", StringComparison.Ordinal))
               && (broker.Count == 0
                   || (broker.Count == 1
                       && string.Equals(broker[0], "rabbitmq", StringComparison.Ordinal)));
    }

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
                using var r = await GetWithBoundaryAsync(http, $"/api/external/mock?delayMs=0&seq={i}&op=0");
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
                using var r = await GetWithBoundaryAsync(http, "/api/payments/history?customerId=1&limit=10");
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
                using var r = await GetWithBoundaryAsync(http, $"/api/external/mock?delayMs={ms}&seq={i}&op=0");
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
                    using var r = await GetWithBoundaryAsync(http, $"/api/external/mock?delayMs=10&seq={seq}&op=0");
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
                using var r = await GetWithBoundaryAsync(http, $"/api/external/mock?delayMs=5&seq={i}&op={i % 7}");
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
                using var r = await GetWithBoundaryAsync(http, $"/api/dispatch/{Channels[i]}?delayMs=80");
                ok += StatusOk(r);
            }
            long wallClockMs = (long)Stopwatch.GetElapsedTime(startNs).TotalMilliseconds;
            return new Dictionary<string, object?>
            {
                ["steps_ok"] = ok,
                ["wall_clock_ms"] = wallClockMs,
            };
        });

    private static async Task<HttpResponseMessage> GetWithBoundaryAsync(HttpClient client, string path)
    {
        Uri url = new(client.BaseAddress ?? throw new InvalidOperationException("self BaseAddress is required"), path);
        using Activity? activity = HttpBoundary.StartActivity("HTTP GET", ActivityKind.Client);
        activity?.SetTag("http.request.method", "GET");
        activity?.SetTag("url.full", url.ToString());
        try
        {
            return await client.GetAsync(path);
        }
        catch (Exception exception)
        {
            activity?.AddEvent(new ActivityEvent(
                "exception",
                tags: new ActivityTagsCollection
                {
                    ["exception.type"] = exception.GetType().FullName,
                    ["exception.message"] = exception.Message,
                }));
            activity?.SetStatus(ActivityStatusCode.Error, exception.Message);
            throw;
        }
    }

    private static async Task<IResult> NPlusOneMessaging(
        HttpRequest request,
        IMessagingFaultService messaging,
        CancellationToken cancellationToken)
    {
        if (!TryQueryInt(request, "messages", 8, out int messages)
            || messages is < 5 or > 100
            || !IsRabbitMq(request))
        {
            return Results.BadRequest();
        }

        return await Timed(
            "n_plus_one_messaging",
            new Dictionary<string, object?> { ["messages"] = messages, ["broker"] = "rabbitmq" },
            async () =>
            {
                MessagingResult result = await messaging.PublishSequentiallyAsync(messages, cancellationToken);
                return new Dictionary<string, object?>
                {
                    ["published"] = result.Published,
                    ["confirmed"] = result.Confirmed,
                };
            });
    }

    private static async Task<IResult> SlowMessaging(
        HttpRequest request,
        IMessagingFaultService messaging,
        CancellationToken cancellationToken)
    {
        if (!TryQueryInt(request, "delayMs", 600, out int delayMs)
            || !TryQueryInt(request, "repeats", 3, out int repeats)
            || delayMs is < 501 or > 5_000
            || repeats is < 3 or > 20
            || !IsRabbitMq(request))
        {
            return Results.BadRequest();
        }

        return await Timed(
            "slow_messaging",
            new Dictionary<string, object?>
            {
                ["delayMs"] = delayMs,
                ["repeats"] = repeats,
                ["broker"] = "rabbitmq",
            },
            async () =>
            {
                MessagingResult result = await messaging.PublishSlowlyAsync(delayMs, repeats, cancellationToken);
                return new Dictionary<string, object?>
                {
                    ["published"] = result.Published,
                    ["confirmed"] = result.Confirmed,
                    ["delay_ms"] = result.DelayMs,
                };
            });
    }
}
