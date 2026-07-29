-- Order Shipping Cost Analysis
-- Analyzes shipping costs

with orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    DATE_TRUNC('month', ordered_at) as order_month,
    count(distinct order_id) as order_count,
    sum(shipping_total) as total_shipping,
    avg(shipping_total) as avg_shipping_cost,
    round(100.0 * sum(shipping_total) / nullif(sum(grand_total), 0), 2) as shipping_pct_of_total,
    sum(case when shipping_total = 0 then 1 else 0 end) as free_shipping_orders
from orders
group by 1
order by 1
