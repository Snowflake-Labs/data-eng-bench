-- Customer Lifetime Revenue Analysis

with customer_revenue as (
    select
        customer_id,
        min(order_date) as first_purchase_date,
        max(order_date) as last_purchase_date,
        count(distinct order_id) as total_orders,
        sum(line_total) as lifetime_revenue,
        avg(line_total) as avg_order_value,
        date_diff('month', min(order_date), max(order_date)) as customer_lifespan_months
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by customer_id
),

revenue_tiers as (
    select
        customer_id,
        first_purchase_date,
        last_purchase_date,
        total_orders,
        round(lifetime_revenue, 2) as lifetime_revenue,
        round(avg_order_value, 2) as avg_order_value,
        customer_lifespan_months,
        case
            when customer_lifespan_months > 0
            then round(lifetime_revenue / customer_lifespan_months, 2)
            else lifetime_revenue
        end as avg_monthly_revenue,
        case
            when lifetime_revenue >= 10000 then 'Platinum (10K+)'
            when lifetime_revenue >= 5000 then 'Gold (5K-10K)'
            when lifetime_revenue >= 1000 then 'Silver (1K-5K)'
            when lifetime_revenue >= 500 then 'Bronze (500-1K)'
            else 'Standard (<500)'
        end as revenue_tier,
        ntile(10) over (order by lifetime_revenue desc) as revenue_decile
    from customer_revenue
)

select * from revenue_tiers
order by lifetime_revenue desc
