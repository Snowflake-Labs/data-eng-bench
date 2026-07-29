-- Return Rate by Product
-- Calculates return rates by product

with order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

return_lines as (
    select * from {{ ref('stg_orders__return_lines') }}
)

select
    ol.product_id,
    ol.sku,
    sum(ol.quantity_ordered) as total_ordered,
    sum(ol.quantity_returned) as total_returned,
    count(distinct ol.order_id) as order_count,
    count(distinct rl.return_id) as return_count,
    round(100.0 * sum(ol.quantity_returned) / nullif(sum(ol.quantity_ordered), 0), 2) as return_rate_pct
from order_lines ol
left join return_lines rl on ol.order_line_id = rl.order_line_id
group by 1, 2
