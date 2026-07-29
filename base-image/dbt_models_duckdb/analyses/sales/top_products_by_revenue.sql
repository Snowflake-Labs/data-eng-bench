-- Top Products by Revenue

with product_revenue as (
    select
        product_id,
        product_name,
        product_category,
        product_brand,
        count(distinct order_id) as order_count,
        sum(quantity_ordered) as units_sold,
        sum(line_total) as total_revenue,
        sum(cost_amount) as total_cost,
        avg(unit_price) as avg_selling_price
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by product_id, product_name, product_category, product_brand
),

final as (
    select
        product_id,
        product_name,
        product_category,
        product_brand,
        order_count,
        units_sold,
        round(total_revenue, 2) as total_revenue,
        round(total_cost, 2) as total_cost,
        round(total_revenue - total_cost, 2) as gross_profit,
        round(100.0 * (total_revenue - total_cost) / nullif(total_revenue, 0), 2) as margin_pct,
        round(avg_selling_price, 2) as avg_selling_price,
        rank() over (order by total_revenue desc) as revenue_rank,
        rank() over (partition by product_category order by total_revenue desc) as category_rank
    from product_revenue
)

select * from final
where revenue_rank <= 100
order by revenue_rank
