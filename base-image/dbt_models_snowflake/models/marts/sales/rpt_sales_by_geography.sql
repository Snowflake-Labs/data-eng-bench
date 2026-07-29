-- Sales by Geography Report
-- Regional performance analysis including revenue, order volume, and average order value
-- broken down by country, state, and city to identify top performing markets

with orders as (
    select * from {{ ref('fct_orders_master') }}
),

customers as (
    select * from {{ ref('dim_customers_enriched') }}
),

-- Aggregate data by location
geo_metrics as (
    select
        c.country_code,
        c.state_province,
        -- City level granularity
        coalesce(c.city, 'Unknown') as city,
        count(distinct o.order_id) as total_orders,
        count(distinct o.customer_id) as unique_customers,
        sum(o.total_amount) as total_revenue,
        avg(o.total_amount) as avg_order_value,
        max(o.ordered_at) as last_order_date
    from orders o
    join customers c on o.customer_id = c.customer_id
    where o.status not in ('CANCELLED', 'RETURNED')
    group by 1, 2, 3
),

-- Calculate global totals for share metrics
global_totals as (
    select
        sum(total_revenue) as global_revenue,
        sum(total_orders) as global_orders
    from geo_metrics
),

-- Final geographic performance report
final as (
    select
        gm.country_code,
        gm.state_province,
        gm.city,
        gm.total_orders,
        gm.unique_customers,
        round(gm.total_revenue, 2) as total_revenue,
        round(gm.avg_order_value, 2) as avg_order_value,
        -- Share of global business
        round(100.0 * gm.total_revenue / nullif(gt.global_revenue, 0), 4) as revenue_share_pct,
        round(100.0 * gm.total_orders / nullif(gt.global_orders, 0), 4) as order_share_pct,
        -- Market penetration proxy (orders per customer)
        round(gm.total_orders::float / nullif(gm.unique_customers, 0), 2) as orders_per_customer,
        -- Recency
        gm.last_order_date,
        DATEDIFF(day, gm.last_order_date, current_date) as days_since_last_sale,
        -- Ranking
        rank() over (partition by gm.country_code order by gm.total_revenue desc) as city_rank_within_country
    from geo_metrics gm
    cross join global_totals gt
)

select * from final
order by total_revenue desc
