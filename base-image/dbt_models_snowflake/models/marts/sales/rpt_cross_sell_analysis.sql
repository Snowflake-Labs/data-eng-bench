-- Sales Cross-Sell Analysis
-- Cross-sell and upsell analysis

with orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

products as (
    select * from {{ ref('stg_product__products') }}
),

product_variants as (
    select * from {{ ref('stg_product__product_variants') }}
),

order_category_count as (
    select
        o.order_id,
        count(distinct p.primary_category_id) as categories_in_order
    from orders o
    left join order_lines ol on o.order_id = ol.order_id
    left join product_variants pv on ol.variant_id = pv.variant_id
    left join products p on pv.product_id = p.product_id
    group by 1
)

select
    DATE_TRUNC('month', o.ordered_at) as order_month,
    case
        when occ.categories_in_order = 1 then 'Single Category'
        when occ.categories_in_order = 2 then 'Cross-Sell (2 categories)'
        else 'Deep Cross-Sell (3+ categories)'
    end as basket_type,
    count(distinct o.order_id) as orders,
    sum(ol.line_total - ol.discount_amount) as revenue,
    sum(ol.line_total - ol.discount_amount) / nullif(count(distinct o.order_id), 0) as avg_order_value
from orders o
left join order_lines ol on o.order_id = ol.order_id
left join order_category_count occ on o.order_id = occ.order_id
group by 1, 2
