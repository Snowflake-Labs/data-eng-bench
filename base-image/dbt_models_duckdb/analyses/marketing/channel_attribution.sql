-- Marketing Channel Attribution Analysis
-- Multi-touch attribution across marketing channels

with customer_touchpoints as (
    select
        customer_id,
        marketing_channel,
        min(order_date) as first_touch,
        max(order_date) as last_touch,
        count(distinct order_id) as orders,
        sum(line_total) as total_revenue
    from {{ ref('fct_sales') }}
    where marketing_channel is not null
        and is_cancelled = false
    group by customer_id, marketing_channel
),

channel_revenue as (
    select
        marketing_channel,
        count(distinct customer_id) as total_customers,
        sum(orders) as total_orders,
        round(sum(total_revenue), 2) as total_revenue,
        round(avg(total_revenue), 2) as avg_revenue_per_customer,
        count(distinct case when first_touch is not null then customer_id end) as first_touch_customers,
        count(distinct case when last_touch is not null then customer_id end) as last_touch_customers
    from customer_touchpoints
    group by marketing_channel
),

attribution_model as (
    select
        marketing_channel,
        total_customers,
        total_orders,
        total_revenue,
        avg_revenue_per_customer,
        first_touch_customers,
        last_touch_customers,
        -- First-touch attribution
        round(total_revenue * (first_touch_customers::decimal / total_customers), 2) as first_touch_attributed_revenue,
        -- Last-touch attribution
        round(total_revenue * (last_touch_customers::decimal / total_customers), 2) as last_touch_attributed_revenue,
        -- Linear attribution (equal weight)
        round(total_revenue / 2.0, 2) as linear_attributed_revenue
    from channel_revenue
)

select * from attribution_model
order by total_revenue desc
