-- Pareto Analysis: Revenue (80/20 Rule)
-- Find products/customers that drive 80% of revenue

with ranked_products as (
    select
        product_id,
        product_name,
        sum(line_total) as total_revenue,
        sum(sum(line_total)) over () as grand_total
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by product_id, product_name
),

cumulative as (
    select
        product_id,
        product_name,
        total_revenue,
        grand_total,
        sum(total_revenue) over (order by total_revenue desc) as cumulative_revenue,
        sum(total_revenue) over (order by total_revenue desc) / grand_total * 100 as cumulative_pct
    from ranked_products
)

select
    product_id,
    product_name,
    total_revenue,
    cumulative_revenue,
    cumulative_pct,
    case
        when cumulative_pct <= 80 then 'A (Top 80%)'
        when cumulative_pct <= 95 then 'B (Next 15%)'
        else 'C (Bottom 5%)'
    end as pareto_class
from cumulative
order by total_revenue desc
