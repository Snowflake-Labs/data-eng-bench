-- Product Price Analysis
-- Analyzes product pricing

with product_prices as (
    select * from {{ ref('stg_product__product_prices') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    pp.price_type,
    pp.currency_code,
    count(distinct pp.variant_id) as variants_priced,
    avg(pp.price_amount) as avg_price,
    min(pp.price_amount) as min_price,
    max(pp.price_amount) as max_price,
    avg(pp.compare_at_price) as avg_compare_at_price,
    avg(pp.cost_price) as avg_cost_price,
    avg(pp.price_amount - pp.cost_price) as avg_margin
from product_prices pp
left join product_variants pv on pp.variant_id = pv.variant_id
group by 1, 2
