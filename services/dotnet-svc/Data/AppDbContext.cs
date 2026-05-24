using DotnetSvc.Models;
using Microsoft.EntityFrameworkCore;

namespace DotnetSvc.Data;

public sealed class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    public DbSet<Order> Orders => Set<Order>();
    public DbSet<OrderItem> OrderItems => Set<OrderItem>();
    public DbSet<Payment> Payments => Set<Payment>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        // The schema `dotnet` is created by the postgres-multistack-schemas
        // Job at lab bootstrap. All tables live under it. Column names
        // use snake_case to match the seed SQL run at startup and to
        // keep cross-stack parity with the other multistack members.
        modelBuilder.HasDefaultSchema("dotnet");

        modelBuilder.Entity<Order>(b =>
        {
            b.ToTable("orders");
            b.HasKey(x => x.Id);
            b.Property(x => x.Id).HasColumnName("id").ValueGeneratedOnAdd();
            b.Property(x => x.Customer).HasColumnName("customer").HasMaxLength(255).IsRequired();
            b.Property(x => x.Status).HasColumnName("status").HasMaxLength(32).IsRequired();
            b.Property(x => x.TotalCents).HasColumnName("total_cents").IsRequired();
            b.Property(x => x.CreatedAt).HasColumnName("created_at");
        });

        modelBuilder.Entity<OrderItem>(b =>
        {
            b.ToTable("order_items");
            b.HasKey(x => x.Id);
            b.Property(x => x.Id).HasColumnName("id").ValueGeneratedOnAdd();
            b.Property(x => x.OrderId).HasColumnName("order_id").IsRequired();
            b.Property(x => x.Sku).HasColumnName("sku").HasMaxLength(64).IsRequired();
            b.Property(x => x.Quantity).HasColumnName("quantity").IsRequired();
            b.Property(x => x.PriceCents).HasColumnName("price_cents").IsRequired();
            b.HasIndex(x => x.OrderId).HasDatabaseName("idx_dotnet_order_items_order_id");
        });

        modelBuilder.Entity<Payment>(b =>
        {
            b.ToTable("payments");
            b.HasKey(x => x.Id);
            b.Property(x => x.Id).HasColumnName("id").ValueGeneratedOnAdd();
            b.Property(x => x.OrderId).HasColumnName("order_id").IsRequired();
            b.Property(x => x.CustomerId).HasColumnName("customer_id").IsRequired();
            b.Property(x => x.AmountCents).HasColumnName("amount_cents").IsRequired();
            b.Property(x => x.Status).HasColumnName("status").HasMaxLength(32).IsRequired();
            b.Property(x => x.CreatedAt).HasColumnName("created_at");
            b.HasIndex(x => x.CustomerId).HasDatabaseName("idx_dotnet_payments_customer_id");
        });
    }
}
