<?php

namespace App\Entity;

use Doctrine\ORM\Mapping as ORM;

#[ORM\Entity]
#[ORM\Table(name: 'order_items')]
class OrderItem
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: 'bigint')]
    public ?string $id = null;

    #[ORM\Column(name: 'order_id', type: 'bigint', nullable: true)]
    public ?string $orderId = null;

    #[ORM\Column(type: 'string', nullable: true)]
    public ?string $sku = null;

    #[ORM\Column(type: 'integer', nullable: true)]
    public ?int $quantity = null;

    #[ORM\Column(name: 'price_cents', type: 'bigint', nullable: true)]
    public ?string $priceCents = null;
}
