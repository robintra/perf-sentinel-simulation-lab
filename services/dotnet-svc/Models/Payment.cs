namespace DotnetSvc.Models;

public sealed class Payment
{
    public long Id { get; set; }
    public long OrderId { get; set; }
    public long CustomerId { get; set; }
    public long AmountCents { get; set; }
    public string Status { get; set; } = "AUTHORIZED";
    public DateTime CreatedAt { get; set; }
}
