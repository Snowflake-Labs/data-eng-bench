-- Product Co-Purchase Analysis
-- Product co-purchase analysis

with order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    p1.product_id as product_id_1,
    p1.product_name as product_name_1,
    p2.product_id as product_id_2,
    p2.product_name as product_name_2,
    count(distinct ol1.order_id) as co_purchase_count,
    count(distinct ol1.order_id) * 1.0 /
        nullif((select count(distinct order_id) from order_lines), 0) as co_purchase_rate
from order_lines ol1
join order_lines ol2 on ol1.order_id = ol2.order_id and ol1.variant_id < ol2.variant_id
left join product_variants pv1 on ol1.variant_id = pv1.variant_id
left join product_variants pv2 on ol2.variant_id = pv2.variant_id
left join products p1 on pv1.product_id = p1.product_id
left join products p2 on pv2.product_id = p2.product_id
group by 1, 2, 3, 4
