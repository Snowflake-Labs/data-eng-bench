-- Product Tag Analysis
-- Analyzes product tags

with product_tags as (
    select * from {{ ref('stg_product__product_tags') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
)

select
    pt.tag_name,
    pt.tag_type,
    count(distinct pt.product_id) as product_count,
    count(distinct pt.tag_id) as tag_assignments
from product_tags pt
left join products p on pt.product_id = p.product_id
group by 1, 2
order by 3 desc
