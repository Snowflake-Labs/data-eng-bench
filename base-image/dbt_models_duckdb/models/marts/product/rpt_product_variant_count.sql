-- Product Variant Count
-- Products by variant count

with product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    p.product_id,
    p.product_name,
    p.lifecycle_status,
    count(distinct pv.variant_id) as variant_count,
    sum(case when pv.is_default then 1 else 0 end) as default_variants,
    min(pv.cost_price) as min_cost,
    max(pv.cost_price) as max_cost
from products p
left join product_variants pv on p.product_id = pv.product_id
group by 1, 2, 3
