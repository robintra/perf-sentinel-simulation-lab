namespace DotnetSvc.Messaging;

public interface IMessagingFaultService
{
    Task<MessagingResult> PublishSequentiallyAsync(int messages, CancellationToken cancellationToken);

    Task<MessagingResult> PublishSlowlyAsync(int delayMs, int repeats, CancellationToken cancellationToken);
}

public sealed record MessagingResult(int Published, int Confirmed, int? DelayMs = null);
