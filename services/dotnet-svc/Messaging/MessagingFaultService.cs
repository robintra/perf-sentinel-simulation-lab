using System.Diagnostics;
using System.Globalization;
using System.Net.Http.Json;
using System.Text;
using RabbitMQ.Client;

namespace DotnetSvc.Messaging;

public sealed class MessagingFaultService(IHttpClientFactory httpClientFactory) : IMessagingFaultService
{
    private const string Destination = "perfsim.dotnet-svc";
    private const string RoutingKey = "dotnet-svc";
    private static readonly ActivitySource ActivitySource = new("DotnetSvc.Messaging");

    public async Task<MessagingResult> PublishSequentiallyAsync(
        int messages,
        CancellationToken cancellationToken)
    {
        TimeSpan operationTimeout = TimeSpan.FromSeconds(5);
        Session session = await OpenSessionAsync(false, operationTimeout, cancellationToken);
        try
        {
            var confirmations = new Task[messages];
            string requestId = Guid.NewGuid().ToString("N", CultureInfo.InvariantCulture);
            for (int index = 0; index < messages; index++)
            {
                byte[] body = Encoding.UTF8.GetBytes($"dotnet-message-{requestId}-{index}");
                confirmations[index] = PublishWithSpanAsync(
                    session.Channel, body, operationTimeout, cancellationToken);
            }

            await Task.WhenAll(confirmations);
            return new MessagingResult(messages, messages);
        }
        finally
        {
            await CloseSessionAsync(session, operationTimeout);
        }
    }

    public async Task<MessagingResult> PublishSlowlyAsync(
        int delayMs,
        int repeats,
        CancellationToken cancellationToken)
    {
        await UpdateLatencyAsync(delayMs, cancellationToken);
        TimeSpan operationTimeout = TimeSpan.FromMilliseconds(delayMs + 5_000);
        Session session = await OpenSessionAsync(true, operationTimeout, cancellationToken);
        try
        {
            string requestId = Guid.NewGuid().ToString("N", CultureInfo.InvariantCulture);
            for (int index = 0; index < repeats; index++)
            {
                byte[] body = Encoding.UTF8.GetBytes($"slow-dotnet-message-{requestId}-{index}");
                await PublishWithSpanAsync(session.Channel, body, operationTimeout, cancellationToken);
            }

            return new MessagingResult(repeats, repeats, delayMs);
        }
        finally
        {
            await CloseSessionAsync(session, operationTimeout);
        }
    }

    private static async Task PublishWithSpanAsync(
        IChannel channel,
        ReadOnlyMemory<byte> body,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        using Activity? activity = ActivitySource.StartActivity($"{Destination} send", ActivityKind.Producer);
        activity?.SetTag("messaging.system", "rabbitmq");
        activity?.SetTag("messaging.destination.name", Destination);
        activity?.SetTag("messaging.operation.type", "send");
        try
        {
            using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutSource.CancelAfter(timeout);
            var properties = new BasicProperties
            {
                ContentType = "text/plain",
                Persistent = true,
            };
            await channel.BasicPublishAsync(
                Destination,
                RoutingKey,
                mandatory: true,
                properties,
                body,
                timeoutSource.Token);
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

    private static async Task<Session> OpenSessionAsync(
        bool slow,
        TimeSpan operationTimeout,
        CancellationToken cancellationToken)
    {
        TimeSpan setupTimeout = TimeSpan.FromTicks(operationTimeout.Ticks * 8);
        var factory = new ConnectionFactory
        {
            HostName = Environment.GetEnvironmentVariable(slow ? "RABBITMQ_SLOW_HOST" : "RABBITMQ_HOST")
                ?? (slow ? "toxiproxy.messaging.svc.cluster.local" : "rabbitmq.messaging.svc.cluster.local"),
            Port = ReadPort(slow ? "RABBITMQ_SLOW_PORT" : "RABBITMQ_PORT", slow ? 25_672 : 5_672),
            UserName = RequiredEnvironment("RABBITMQ_USERNAME"),
            Password = RequiredEnvironment("RABBITMQ_PASSWORD"),
            AutomaticRecoveryEnabled = false,
            TopologyRecoveryEnabled = false,
            RequestedConnectionTimeout = setupTimeout,
            HandshakeContinuationTimeout = setupTimeout,
            ContinuationTimeout = operationTimeout,
        };

        using var setupSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        setupSource.CancelAfter(setupTimeout);
        IConnection connection = await factory.CreateConnectionAsync(setupSource.Token);
        IChannel? channel = null;
        try
        {
            channel = await connection.CreateChannelAsync(
                new CreateChannelOptions(
                    publisherConfirmationsEnabled: true,
                    publisherConfirmationTrackingEnabled: true),
                setupSource.Token);
            await channel.ExchangeDeclareAsync(
                Destination, ExchangeType.Direct, durable: true, autoDelete: false,
                cancellationToken: setupSource.Token);
            await channel.QueueDeclareAsync(
                Destination, durable: true, exclusive: false, autoDelete: false,
                arguments: new Dictionary<string, object?> { ["x-message-ttl"] = 60_000 },
                cancellationToken: setupSource.Token);
            await channel.QueueBindAsync(
                Destination, Destination, RoutingKey,
                cancellationToken: setupSource.Token);
            return new Session(connection, channel);
        }
        catch
        {
            if (channel is not null)
            {
                await CloseChannelBestEffortAsync(channel, operationTimeout);
            }
            await CloseConnectionBestEffortAsync(connection, operationTimeout);
            throw;
        }
    }

    private static async Task CloseSessionAsync(Session session, TimeSpan timeout)
    {
        Exception? failure = null;
        try
        {
            using var channelClose = new CancellationTokenSource(timeout);
            await session.Channel.CloseAsync(channelClose.Token);
        }
        catch (Exception exception)
        {
            failure = exception;
        }

        try
        {
            using var connectionClose = new CancellationTokenSource(timeout);
            await session.Connection.CloseAsync(
                Constants.ReplySuccess, "request complete", timeout, abort: false,
                connectionClose.Token);
        }
        catch (Exception exception)
        {
            failure ??= exception;
        }

        Exception? channelDisposeFailure = await DisposeAsync(session.Channel, timeout);
        failure ??= channelDisposeFailure;
        Exception? connectionDisposeFailure = await DisposeAsync(session.Connection, timeout);
        failure ??= connectionDisposeFailure;
        if (failure is not null)
        {
            throw failure;
        }
    }

    private static async Task CloseChannelBestEffortAsync(IChannel channel, TimeSpan timeout)
    {
        try
        {
            using var closeSource = new CancellationTokenSource(timeout);
            await channel.CloseAsync(closeSource.Token);
        }
        catch
        {
            // Preserve the setup failure.
        }
        _ = await DisposeAsync(channel, timeout);
    }

    private static async Task CloseConnectionBestEffortAsync(IConnection connection, TimeSpan timeout)
    {
        try
        {
            using var closeSource = new CancellationTokenSource(timeout);
            await connection.CloseAsync(
                Constants.ReplySuccess, "setup failed", timeout, abort: true,
                closeSource.Token);
        }
        catch
        {
            // Preserve the setup failure.
        }
        _ = await DisposeAsync(connection, timeout);
    }

    private static async Task<Exception?> DisposeAsync(IAsyncDisposable disposable, TimeSpan timeout)
    {
        try
        {
            await disposable.DisposeAsync().AsTask().WaitAsync(timeout);
            return null;
        }
        catch (Exception exception)
        {
            return exception;
        }
    }

    private async Task UpdateLatencyAsync(int delayMs, CancellationToken cancellationToken)
    {
        string baseUrl = (Environment.GetEnvironmentVariable("TOXIPROXY_API")
            ?? "http://toxiproxy.messaging.svc.cluster.local:8474").TrimEnd('/');
        string updateUrl = $"{baseUrl}/proxies/rabbitmq-slow/toxics/latency_downstream";
        using HttpResponseMessage update = await PostJsonAsync(
            updateUrl,
            new { attributes = new { latency = delayMs, jitter = 0 } },
            cancellationToken);
        if (update.StatusCode != System.Net.HttpStatusCode.NotFound)
        {
            update.EnsureSuccessStatusCode();
            return;
        }

        using HttpResponseMessage create = await PostJsonAsync(
            $"{baseUrl}/proxies/rabbitmq-slow/toxics",
            new
            {
                name = "latency_downstream",
                type = "latency",
                stream = "downstream",
                attributes = new { latency = delayMs, jitter = 0 },
            },
            cancellationToken);
        if (create.StatusCode == System.Net.HttpStatusCode.Conflict)
        {
            using HttpResponseMessage retry = await PostJsonAsync(
                updateUrl,
                new { attributes = new { latency = delayMs, jitter = 0 } },
                cancellationToken);
            retry.EnsureSuccessStatusCode();
            return;
        }
        create.EnsureSuccessStatusCode();
    }

    private async Task<HttpResponseMessage> PostJsonAsync(
        string url,
        object body,
        CancellationToken cancellationToken)
    {
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(TimeSpan.FromSeconds(5));
        return await httpClientFactory.CreateClient("toxiproxy")
            .PostAsJsonAsync(url, body, timeoutSource.Token);
    }

    private static string RequiredEnvironment(string name)
    {
        string? value = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(value)
            ? throw new InvalidOperationException($"{name} is required")
            : value;
    }

    private static int ReadPort(string name, int fallback)
    {
        string? value = Environment.GetEnvironmentVariable(name);
        if (value is null)
        {
            return fallback;
        }
        return int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out int port)
               && port is >= 1 and <= 65_535
            ? port
            : throw new InvalidOperationException($"{name} must be a valid port");
    }

    private sealed record Session(IConnection Connection, IChannel Channel);
}
