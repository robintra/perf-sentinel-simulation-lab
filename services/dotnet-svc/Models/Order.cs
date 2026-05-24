namespace DotnetSvc.Models;

public sealed class Order
{
    public long Id { get; set; }
    public string Customer { get; set; } = "";
    public string Status { get; set; } = "PENDING";
    public long TotalCents { get; set; }
    public DateTime CreatedAt { get; set; }
}
