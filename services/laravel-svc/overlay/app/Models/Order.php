<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Order extends Model
{
    protected $table = 'orders';
    public $timestamps = false;
    protected $guarded = [];

    public function items()
    {
        return $this->hasMany(OrderItem::class, 'order_id');
    }
}
