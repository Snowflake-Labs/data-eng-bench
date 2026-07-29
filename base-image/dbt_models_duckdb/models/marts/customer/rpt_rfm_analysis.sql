-- Customer RFM Analysis
-- Customer RFM segmentation with quintile scoring

with customers as (
    select * from {{ ref('stg_customer__customers') }}
),

orders as (
    select * from {{ ref('stg_orders__orders') }}
),

order_lines as (
    select * from {{ ref('stg_orders__order_lines') }}
),

-- First calculate the RFM metrics per customer
customer_metrics as (
    select
        c.customer_id,
        -- Recency: days since last order
        date_diff('day', max(o.ordered_at), current_date) as days_since_last_order,
        -- Frequency: total orders
        count(distinct o.order_id) as total_orders,
        -- Monetary: total spend
        coalesce(sum(ol.line_total - ol.discount_amount), 0) as total_spend,
        coalesce(avg(ol.line_total - ol.discount_amount), 0) as avg_order_value
    from customers c
    left join orders o on c.customer_id = o.customer_id
    left join order_lines ol on o.order_id = ol.order_id
    where o.order_id is not null
    group by c.customer_id
)

-- Then apply window functions for scoring
select
    customer_id,
    days_since_last_order,
    total_orders,
    total_spend,
    avg_order_value,
    -- RFM Scores (using quintiles)
    ntile(5) over (order by days_since_last_order desc) as recency_score,
    ntile(5) over (order by total_orders) as frequency_score,
    ntile(5) over (order by total_spend) as monetary_score
from customer_metrics