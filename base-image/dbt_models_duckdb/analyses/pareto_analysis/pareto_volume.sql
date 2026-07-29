-- Pareto Analysis: Volume (80/20 Rule)
-- Find products that account for 80% of unit sales volume

with product_volume as (
    select
        product_id,
        product_name,
        product_category,
        sum(quantity_ordered) as total_units_sold,
        count(distinct order_id) as order_count,
        sum(sum(quantity_ordered)) over () as grand_total_units
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by product_id, product_name, product_category
),

cumulative_volume as (
    select
        product_id,
        product_name,
        product_category,
        total_units_sold,
        order_count,
        sum(total_units_sold) over (order by total_units_sold desc) as cumulative_units,
        round(100.0 * sum(total_units_sold) over (order by total_units_sold desc) / grand_total_units, 2) as cumulative_pct,
        round(100.0 * total_units_sold / grand_total_units, 2) as pct_of_total_volume
    from product_volume
)

select
    product_id,
    product_name,
    product_category,
    total_units_sold,
    order_count,
    cumulative_units,
    cumulative_pct,
    pct_of_total_volume,
    case
        when cumulative_pct <= 80 then 'A (Top 80% Volume)'
        when cumulative_pct <= 95 then 'B (Next 15% Volume)'
        else 'C (Bottom 5% Volume)'
    end as pareto_class
from cumulative_volume
order by total_units_sold desc
