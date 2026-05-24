using DotnetSvc.Data;
using DotnetSvc.Models;
using Microsoft.EntityFrameworkCore;

namespace DotnetSvc.Endpoints;

/// <summary>
/// /api/external/mock, /api/dispatch/{channel}, /api/payments/history.
/// Callees for the HTTP-side faults. /api/payments/history returns an
/// array of positional arrays [id, order_id, customer_id, amount_cents,
/// status] to match the multistack contract (helidon-mp / mutiny /
/// quarkus all return List&lt;Object[]&gt;).
/// </summary>
internal static class BusinessEndpoints
{
    private static readonly HashSet<string> Channels =
            new(StringComparer.Ordinal) { "email", "sms", "push", "webhook", "slack", "teams" };

    public static IEndpointRouteBuilder MapBusinessEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/external/mock", async (long? delayMs, int? seq, int? op) =>
        {
            long d = delayMs ?? 0L;
            if (d > 0)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(d));
            }
            return Results.Json(new { ok = true, seq = seq ?? 0, op = op ?? 0, delayMs = d });
        });

        app.MapGet("/api/dispatch/{channel}", async (string channel, long? delayMs) =>
        {
            if (!Channels.Contains(channel))
            {
                return Results.NotFound(new { error = "unknown channel" });
            }
            long d = delayMs ?? 0L;
            if (d > 0)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(d));
            }
            return Results.Json(new { channel, dispatched = true, delayMs = d });
        });

        app.MapGet("/api/payments/history", async (long? customerId, int? limit, AppDbContext db) =>
        {
            long c = customerId ?? 1L;
            int safeLimit = Math.Clamp(limit ?? 10, 1, 100);
            List<Payment> rows = await db.Payments
                    .Where(p => p.CustomerId == c)
                    .OrderBy(p => p.Id)
                    .Take(safeLimit)
                    .ToListAsync();
            object[] arr = rows
                    .Select(p => new object[]
                    {
                        p.Id, p.OrderId, p.CustomerId, p.AmountCents, p.Status
                    })
                    .ToArray();
            return Results.Json(arr);
        });

        return app;
    }
}
