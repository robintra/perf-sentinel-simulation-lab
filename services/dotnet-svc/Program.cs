using DotnetSvc.Data;
using DotnetSvc.Endpoints;
using DotnetSvc.Messaging;
using Microsoft.EntityFrameworkCore;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

// dotnet-svc: .NET 10 LTS multistack member. Minimal API, EF Core 10
// + Npgsql (with the OpenTelemetry EF Core ActivitySource that emits
// the `OpenTelemetry.Instrumentation.EntityFrameworkCore` scope used
// by perf-sentinel's strict classifier as the ORM marker).
//
// Env overrides:
//   HTTP_PORT: overrides Service:Port from appsettings
//   SELF_BASE_URL: overrides Service:SelfBaseUrl
//   ConnectionStrings__Default: overrides the DB connection string
//   OTEL_*: standard OTel env vars consumed by the OTel SDK
var builder = WebApplication.CreateBuilder(args);

int httpPort = EnvOrInt("HTTP_PORT", builder.Configuration.GetValue<int?>("Service:Port") ?? 8087);
string selfBaseUrl = EnvOr("SELF_BASE_URL",
        builder.Configuration["Service:SelfBaseUrl"] ?? $"http://localhost:{httpPort}");
bool disableTelemetry = builder.Configuration.GetValue<bool>("Service:DisableTelemetry");
bool skipSchemaBootstrap = builder.Configuration.GetValue<bool>("Service:SkipSchemaBootstrap");

builder.WebHost.ConfigureKestrel(k => k.ListenAnyIP(httpPort));

string connectionString = builder.Configuration.GetConnectionString("Default")
        ?? throw new InvalidOperationException("ConnectionStrings:Default is required");

builder.Services.AddDbContextPool<AppDbContext>(opts =>
        opts.UseNpgsql(connectionString, npg => npg.MigrationsHistoryTable("__efmigrations_history", "dotnet")),
        poolSize: 16);

builder.Services.AddHttpClient("self", c =>
{
    c.BaseAddress = new Uri(selfBaseUrl);
    // Cap each self-loop call so a hung downstream cannot pin the
    // handler indefinitely. 15 s is loose enough for the 6 × 600 ms
    // slow-http worst case + scheduling jitter.
    c.Timeout = TimeSpan.FromSeconds(15);
});
builder.Services.AddHttpClient("toxiproxy", c => c.Timeout = TimeSpan.FromSeconds(5));
builder.Services.AddSingleton<IMessagingFaultService, MessagingFaultService>();

if (!disableTelemetry)
{
    builder.Services.AddOpenTelemetry()
            .ConfigureResource(r => r.AddService(
                    serviceName: Environment.GetEnvironmentVariable("OTEL_SERVICE_NAME") ?? "dotnet-svc"))
            .WithTracing(t => t
                    .AddAspNetCoreInstrumentation()
                    .AddHttpClientInstrumentation()
                    .AddEntityFrameworkCoreInstrumentation()
                    .AddSource("DotnetSvc.HttpBoundary", "DotnetSvc.Messaging")
                    .AddOtlpExporter());
}

var app = builder.Build();

if (!skipSchemaBootstrap)
{
    await using var scope = app.Services.CreateAsyncScope();
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    await SchemaBootstrap.EnsureSchemaAsync(db);
}

app.MapGet("/health/live", () => Results.Json(new { status = "UP" }));
app.MapGet("/health/ready", () => Results.Json(new { status = "UP" }));

app.MapFaultEndpoints();
app.MapBusinessEndpoints();

app.Run();

static string EnvOr(string key, string fallback)
{
    string? v = Environment.GetEnvironmentVariable(key);
    return string.IsNullOrWhiteSpace(v) ? fallback : v;
}

static int EnvOrInt(string key, int fallback)
{
    string? v = Environment.GetEnvironmentVariable(key);
    return int.TryParse(v, out int parsed) ? parsed : fallback;
}

public partial class Program { }
