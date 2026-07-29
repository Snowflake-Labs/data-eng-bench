-- Wishlist Item Popularity
-- Popular wishlist items

with wishlist_items as (
    select * from {{ ref('stg_digital__wishlist_items') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
)

select
    wi.variant_id,
    pv.sku,
    pv.variant_name,
    count(distinct wi.wishlist_id) as wishlists_containing,
    avg(wi.priority) as avg_priority
from wishlist_items wi
left join product_variants pv on wi.variant_id = pv.variant_id
group by 1, 2, 3
order by 4 desc
