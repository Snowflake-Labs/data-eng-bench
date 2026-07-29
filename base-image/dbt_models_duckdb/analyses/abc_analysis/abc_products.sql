-- ABC Product Classification
-- Classifies products into A (top 20% revenue), B (next 30%), C (remaining 50%)

with product_revenue as (
    select
        product_id,
        product_name,
        sum(line_total) as total_revenue,
        sum(quantity_ordered) as total_units_sold,
        count(distinct order_id) as order_count,
        count(distinct customer_id) as unique_customers
    from {{ ref('fct_sales') }}
    where product_id is not null
        and is_cancelled = false
    group by product_id, product_name
),

ranked_products as (
    select
        product_id,
        product_name,
        total_revenue,
        total_units_sold,
        order_count,
        unique_customers,
        sum(total_revenue) over () as grand_total,
        sum(total_revenue) over (order by total_revenue desc) as cumulative_revenue,
        row_number() over (order by total_revenue desc) as revenue_rank
    from product_revenue
),

classified_products as (
    select
        product_id,
        product_name,
        total_revenue,
        total_units_sold,
        order_count,
        unique_customers,
        revenue_rank,
        round(100.0 * total_revenue / grand_total, 2) as pct_of_total_revenue,
        round(100.0 * cumulative_revenue / grand_total, 2) as cumulative_pct,
        case
            when cumulative_revenue / grand_total <= 0.80 then 'A - Top 80% Revenue'
            when cumulative_revenue / grand_total <= 0.95 then 'B - Next 15% Revenue'
            else 'C - Bottom 5% Revenue'
        end as abc_class
    from ranked_products
)

select
    abc_class,
    count(*) as product_count,
    sum(total_revenue) as total_revenue,
    round(avg(total_revenue), 2) as avg_revenue_per_product,
    sum(total_units_sold) as total_units_sold,
    round(avg(total_units_sold), 2) as avg_units_per_product,
    sum(unique_customers) as total_customer_interactions
from classified_products
group by abc_class
order by
    case abc_class
        when 'A - Top 80% Revenue' then 1
        when 'B - Next 15% Revenue' then 2
        when 'C - Bottom 5% Revenue' then 3
    end
