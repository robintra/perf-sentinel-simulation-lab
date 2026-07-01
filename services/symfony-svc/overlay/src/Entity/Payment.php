<?php

namespace App\Entity;

use Doctrine\ORM\Mapping as ORM;

#[ORM\Entity]
#[ORM\Table(name: 'payments')]
class Payment
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: 'bigint')]
    public ?string $id = null;

    #[ORM\Column(name: 'order_id', type: 'bigint', nullable: true)]
    public ?string $orderId = null;

    #[ORM\Column(name: 'customer_id', type: 'bigint', nullable: true)]
    public ?string $customerId = null;

    #[ORM\Column(name: 'amount_cents', type: 'bigint', nullable: true)]
    public ?string $amountCents = null;

    #[ORM\Column(type: 'string', nullable: true)]
    public ?string $status = null;
}
