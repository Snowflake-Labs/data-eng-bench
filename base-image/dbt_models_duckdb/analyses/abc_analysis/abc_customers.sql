-- ABC Customer Classification
-- Classifies customers into A (top 20% revenue), B (next 30%), C (remaining 50%)

with customer_revenue as (
    select
        customer_id,
        sum(line_total) as total_revenue,
        count(distinct order_id) as order_count,
        min(order_date) as first_order_date,
        max(order_date) as last_order_date
    from {{ ref('fct_sales') }}
    where customer_id is not null
        and is_cancelled = false
    group by customer_id
),

ranked_customers as (
    select
        customer_id,
        total_revenue,
        order_count,
        first_order_date,
        last_order_date,
        sum(total_revenue) over () as grand_total,
        sum(total_revenue) over (order by total_revenue desc) as cumulative_revenue,
        row_number() over (order by total_revenue desc) as revenue_rank
    from customer_revenue
),

classified_customers as (
    select
        customer_id,
        total_revenue,
        order_count,
        first_order_date,
        last_order_date,
        revenue_rank,
        round(100.0 * total_revenue / grand_total, 2) as pct_of_total_revenue,
        round(100.0 * cumulative_revenue / grand_total, 2) as cumulative_pct,
        case
            when cumulative_revenue / grand_total <= 0.80 then 'A - Top 80% Revenue'
            when cumulative_revenue / grand_total <= 0.95 then 'B - Next 15% Revenue'
            else 'C - Bottom 5% Revenue'
        end as abc_class
    from ranked_customers
)

select
    abc_class,
    count(*) as customer_count,
    sum(total_revenue) as total_revenue,
    round(avg(total_revenue), 2) as avg_revenue_per_customer,
    sum(order_count) as total_orders,
    round(avg(order_count), 2) as avg_orders_per_customer
from classified_customers
group by abc_class
order by
    case abc_class
        when 'A - Top 80% Revenue' then 1
        when 'B - Next 15% Revenue' then 2
        when 'C - Bottom 5% Revenue' then 3
    end
