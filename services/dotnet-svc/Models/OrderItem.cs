namespace DotnetSvc.Models;

public sealed class OrderItem
{
    public long Id { get; set; }
    public long OrderId { get; set; }
    public string Sku { get; set; } = "";
    public int Quantity { get; set; }
    public long PriceCents { get; set; }
}
