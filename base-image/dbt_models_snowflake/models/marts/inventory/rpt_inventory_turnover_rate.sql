with src_stg_product__products as (
    select * from {{ ref('stg_product__products') }}
),
cogs as (
    select
        variant_id,
        sum(quantity * unit_cost) as total_cogs
    from {{ ref('stg_inventory__inventory_transactions') }}
    where transaction_type = 'OUTBOUND'
    group by 1
),
avg_inv as (
    select
        variant_id,
        avg(quantity_on_hand * unit_cost) as avg_inventory_value
    from {{ ref('stg_inventory__inventory_snapshots') }}
    group by 1
)

select
    c.variant_id,
    p.product_name,
    c.total_cogs,
    a.avg_inventory_value,
    case when a.avg_inventory_value > 0 then c.total_cogs / a.avg_inventory_value else 0 end as turnover_ratio
from cogs c
join avg_inv a on c.variant_id = a.variant_id
left join src_stg_product__products p on c.variant_id = p.product_id
