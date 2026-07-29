with levels as (
    select variant_id, sum(quantity_on_hand) as total_on_hand
    from {{ ref('stg_inventory__inventory_levels') }}
    group by 1
),
rules as (
    select * from {{ ref('stg_inventory__reorder_rules') }}
)

select
    l.variant_id,
    l.total_on_hand,
    r.min_quantity,
    r.reorder_quantity,
    (r.min_quantity - l.total_on_hand) as shortage
from levels l
join rules r on l.variant_id = r.variant_id
where l.total_on_hand <= r.min_quantity
