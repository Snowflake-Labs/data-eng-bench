-- Order Line Discount Summary
-- Summarizes discounts at line level

with order_line_discounts as (
    select * from {{ ref('stg_orders__order_line_discounts') }}
)

select
    discount_type,
    count(distinct discount_id) as discount_applications,
    count(distinct order_line_id) as lines_with_discount,
    sum(discount_amount) as total_discount,
    avg(discount_amount) as avg_discount,
    min(discount_amount) as min_discount,
    max(discount_amount) as max_discount
from order_line_discounts
group by 1
