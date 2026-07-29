-- Brand Revenue Share Report
-- Analysis of sales performance by brand including revenue share,
-- unit volume, and product diversity to guide merchandising strategy

with src_stg_product__brands as (
    select * from {{ ref('stg_product__brands') }}
),

src_stg_product__products as (
    select * from {{ ref('stg_product__products') }}
),

-- Aggregate sales by brand
brand_sales as (
    select 
        p.brand_id,
        count(distinct ol.order_id) as total_orders_containing_brand,
        count(distinct ol.product_id) as distinct_products_sold,
        sum(ol.quantity_ordered) as total_units_sold,
        sum(ol.quantity_ordered * ol.unit_price) as brand_revenue,
        avg(ol.unit_price) as avg_unit_price
    from {{ ref('stg_orders__order_lines') }} ol
    join src_stg_product__products p on ol.product_id = p.product_id
    group by 1
),

-- Company-wide specific totals for comparison
total_sales as (
    select 
        sum(grand_total) as total_revenue,
        count(distinct order_id) as total_company_orders
    from {{ ref('stg_orders__orders') }}
)

select 
    b.brand_id,
    b.brand_name,
    b.brand_code,
    -- Revenue Metrics
    coalesce(bs.brand_revenue, 0) as brand_revenue,
    (coalesce(bs.brand_revenue, 0) * 100.0 / nullif(ts.total_revenue, 0)) as revenue_share_pct,
    -- Volume Metrics
    coalesce(bs.total_units_sold, 0) as total_units_sold,
    coalesce(bs.distinct_products_sold, 0) as distinct_products_sold,
    round(coalesce(bs.avg_unit_price, 0), 2) as avg_unit_price,
    -- Penetration
    round(100.0 * coalesce(bs.total_orders_containing_brand, 0) / nullif(ts.total_company_orders, 0), 2) as order_penetration_pct,
    -- Ranking
    rank() over (order by coalesce(bs.brand_revenue, 0) desc) as revenue_rank
from src_stg_product__brands b
left join brand_sales bs on b.brand_id = bs.brand_id
cross join total_sales ts
where b.is_active = true
order by revenue_share_pct desc nulls last