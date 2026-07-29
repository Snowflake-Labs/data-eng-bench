with monthly_orders as (
    select 
        customer_id,
        date_trunc('month', ordered_at) as order_month,
        sum(grand_total) as monthly_revenue
    from {{ ref('stg_orders__orders') }}
    group by 1,2
),
lagged as (
    select
        customer_id,
        order_month,
        monthly_revenue as current_revenue,
        lag(monthly_revenue) over (partition by customer_id order by order_month) as prev_revenue
    from monthly_orders
)

select
    order_month,
    sum(case when prev_revenue is null and current_revenue > 0 then current_revenue else 0 end) as new_revenue,
    sum(case when prev_revenue > 0 and current_revenue is null then -prev_revenue else 0 end) as churned_revenue,
    sum(case when current_revenue > prev_revenue and prev_revenue > 0 then (current_revenue - prev_revenue) else 0 end) as expansion_revenue,
    sum(case when current_revenue < prev_revenue and current_revenue > 0 then (current_revenue - prev_revenue) else 0 end) as contraction_revenue
from lagged
group by 1