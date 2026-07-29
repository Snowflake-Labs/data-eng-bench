-- Product Price History
-- Tracks price changes

with product_prices as (
    select * from {{ ref('stg_product__product_prices') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    pp.variant_id,
    pv.sku,
    pv.variant_name,
    pp.price_type,
    pp.currency_code,
    pp.price_amount,
    pp.effective_from,
    pp.effective_to,
    lag(pp.price_amount) over (partition by pp.variant_id, pp.price_type, pp.currency_code order by pp.effective_from) as previous_price,
    pp.price_amount - lag(pp.price_amount) over (partition by pp.variant_id, pp.price_type, pp.currency_code order by pp.effective_from) as price_change
from product_prices pp
left join product_variants pv on pp.variant_id = pv.variant_id
