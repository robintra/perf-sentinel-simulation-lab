using DotnetSvc.Data;
using DotnetSvc.Messaging;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;

namespace DotnetSvc.Tests;

public sealed class MessagingInvalidContractTests : IClassFixture<MessagingInvalidContractFactory>
{
    private readonly MessagingInvalidContractFactory _factory;

    public MessagingInvalidContractTests(MessagingInvalidContractFactory factory)
    {
        _factory = factory;
    }

    [Fact]
    public async Task MessagingInvalidContractRejectsSevenRequestsBeforeAnyBoundaryCall()
    {
        using HttpClient client = _factory.CreateClient();
        string[] paths =
        [
            "/api/fault/n-plus-one-messaging?messages=4&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=101&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=500&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=5001&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=2&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=21&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=8&broker=unsupported",
        ];

        foreach (string path in paths)
        {
            using HttpResponseMessage response = await client.PostAsync(path, null);
            Assert.Equal(400, (int)response.StatusCode);
        }

        Assert.Equal(0, _factory.Messaging.SequentialCalls);
        Assert.Equal(0, _factory.Messaging.SlowCalls);
        Assert.Equal(0, _factory.DatabaseCalls);
        Assert.Equal(0, _factory.SelfHttpCalls);
        Console.WriteLine("PERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0");
    }

    [Fact]
    public async Task MessagingInvalidContractRejectsMalformedParametersBeforeAnyBoundaryCall()
    {
        using HttpClient client = _factory.CreateClient();
        string[] paths =
        [
            "/api/fault/n-plus-one-messaging?messages[]=8&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=8items&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=%208&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=%2B8&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=999999999999999999999999999999&broker=rabbitmq",
            "/api/fault/n-plus-one-messaging?messages=8&messages=9&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs[]=600&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600ms&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=%20600&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=%2B600&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=999999999999999999999999999999&repeats=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats[]=3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=3times&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=%203&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=%2B3&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=999999999999999999999999999999&broker=rabbitmq",
            "/api/fault/slow-messaging?delayMs=600&repeats=3&broker=rabbitmq&broker=rabbitmq",
        ];

        foreach (string path in paths)
        {
            using HttpResponseMessage response = await client.PostAsync(path, null);
            Assert.Equal(400, (int)response.StatusCode);
        }

        Assert.Equal(0, _factory.Messaging.SequentialCalls);
        Assert.Equal(0, _factory.Messaging.SlowCalls);
        Assert.Equal(0, _factory.DatabaseCalls);
        Assert.Equal(0, _factory.SelfHttpCalls);
    }
}

public sealed class MessagingInvalidContractFactory : WebApplicationFactory<Program>
{
    internal MessagingSpy Messaging { get; } = new();
    internal int DatabaseCalls;
    internal int SelfHttpCalls;

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseSetting("Service:SkipSchemaBootstrap", "true");
        builder.UseSetting("Service:DisableTelemetry", "true");
        builder.ConfigureTestServices(services =>
        {
            for (int index = services.Count - 1; index >= 0; index--)
            {
                Type serviceType = services[index].ServiceType;
                if (serviceType == typeof(AppDbContext)
                    || serviceType == typeof(DbContextOptions<AppDbContext>)
                    || (serviceType.IsGenericType
                        && serviceType.GetGenericArguments().Contains(typeof(AppDbContext))))
                {
                    services.RemoveAt(index);
                }
            }
            services.AddDbContext<AppDbContext>(options => options
                .UseInMemoryDatabase("messaging-invalid-contract")
                .LogTo(_ => Interlocked.Increment(ref DatabaseCalls)));

            services.RemoveAll<IMessagingFaultService>();
            services.AddSingleton<IMessagingFaultService>(Messaging);
            services.AddHttpClient("self")
                .ConfigurePrimaryHttpMessageHandler(() => new TripwireHandler(
                    () => Interlocked.Increment(ref SelfHttpCalls)));
        });
    }
}

internal sealed class MessagingSpy : IMessagingFaultService
{
    internal int SequentialCalls;
    internal int SlowCalls;

    public Task<MessagingResult> PublishSequentiallyAsync(int messages, CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref SequentialCalls);
        throw new InvalidOperationException("messaging boundary called");
    }

    public Task<MessagingResult> PublishSlowlyAsync(int delayMs, int repeats, CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref SlowCalls);
        throw new InvalidOperationException("messaging boundary called");
    }
}

internal sealed class TripwireHandler(Action onCall) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        onCall();
        throw new InvalidOperationException("self HTTP boundary called");
    }
}
