-- Order Discount Analysis
-- Analyzes discounts applied to orders

with order_line_discounts as (
    select * from {{ ref('stg_orders__order_line_discounts') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
)

select
    old.discount_type,
    old.discount_code,
    count(distinct ol.order_id) as orders_with_discount,
    count(distinct old.discount_id) as discount_applications,
    sum(old.discount_amount) as total_discount_amount,
    avg(old.discount_amount) as avg_discount_amount
from order_line_discounts old
left join order_lines ol on old.order_line_id = ol.order_line_id
left join orders o on ol.order_id = o.order_id
group by 1, 2
