-- Landed Cost Summary
-- Summarizes landed costs

with landed_cost_components as (
    select * from {{ ref('stg_procurement__landed_cost_components') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    lcc.component_type,
    lcc.currency_code,
    count(distinct lcc.variant_id) as variants_with_component,
    sum(lcc.amount) as total_amount,
    avg(lcc.amount) as avg_amount
from landed_cost_components lcc
left join product_variants pv on lcc.variant_id = pv.variant_id
group by 1, 2
