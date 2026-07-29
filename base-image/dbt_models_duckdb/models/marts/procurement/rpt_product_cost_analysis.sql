-- Product Cost Analysis
-- Analyzes product costs

with product_costs as (
    select * from {{ ref('stg_procurement__product_costs') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

suppliers as (
    select * from {{ ref('stg_procurement__suppliers') }}
)

select
    pc.cost_type,
    s.supplier_name,
    count(distinct pc.variant_id) as variants_priced,
    avg(pc.unit_cost) as avg_unit_cost,
    min(pc.unit_cost) as min_cost,
    max(pc.unit_cost) as max_cost
from product_costs pc
left join product_variants pv on pc.variant_id = pv.variant_id
left join suppliers s on pc.supplier_id = s.supplier_id
where pc.effective_to is null or pc.effective_to > current_date
group by 1, 2
