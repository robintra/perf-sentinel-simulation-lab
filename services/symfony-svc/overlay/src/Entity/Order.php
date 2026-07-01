<?php

namespace App\Entity;

use Doctrine\ORM\Mapping as ORM;

#[ORM\Entity]
#[ORM\Table(name: 'orders')]
class Order
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column(type: 'bigint')]
    public ?string $id = null;

    #[ORM\Column(type: 'string', nullable: true)]
    public ?string $customer = null;

    #[ORM\Column(type: 'string', nullable: true)]
    public ?string $status = null;

    #[ORM\Column(name: 'total_cents', type: 'bigint', nullable: true)]
    public ?string $totalCents = null;
}
