-- Pareto Analysis: Profit (80/20 Rule)
-- Find products that drive 80% of profit

with product_profit as (
    select
        product_id,
        product_name,
        product_category,
        sum(line_total) as total_revenue,
        sum(cost_amount) as total_cost,
        sum(line_total - cost_amount) as total_profit,
        sum(sum(line_total - cost_amount)) over () as grand_total_profit
    from {{ ref('fct_sales') }}
    where is_cancelled = false
        and cost_amount is not null
    group by product_id, product_name, product_category
),

cumulative_profit as (
    select
        product_id,
        product_name,
        product_category,
        round(total_revenue, 2) as total_revenue,
        round(total_cost, 2) as total_cost,
        round(total_profit, 2) as total_profit,
        round(100.0 * total_profit / nullif(total_revenue, 0), 2) as profit_margin_pct,
        sum(total_profit) over (order by total_profit desc) as cumulative_profit,
        round(100.0 * sum(total_profit) over (order by total_profit desc) / grand_total_profit, 2) as cumulative_pct
    from product_profit
    where total_profit > 0
)

select
    product_id,
    product_name,
    product_category,
    total_revenue,
    total_cost,
    total_profit,
    profit_margin_pct,
    cumulative_profit,
    cumulative_pct,
    case
        when cumulative_pct <= 80 then 'A (Top 80% Profit)'
        when cumulative_pct <= 95 then 'B (Next 15% Profit)'
        else 'C (Bottom 5% Profit)'
    end as pareto_class
from cumulative_profit
order by total_profit desc
