{{
    config(
        materialized='view',
        tags=['comparison', 'sales', 'mom']
    )
}}

/*
 * MOM Comparison for Sales
 */

with current_period as (
    select
        DATE_TRUNC('month', order_date) as period,
        sum(line_total) as revenue,
        count(distinct order_id) as orders
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by DATE_TRUNC('month', order_date)
),

prior_period as (
    select
        DATEADD(month, 1, period) as period,
        revenue as prior_revenue,
        orders as prior_orders
    from current_period
),

comparison as (
    select
        c.period,
        c.revenue as current_revenue,
        p.prior_revenue,
        c.revenue - p.prior_revenue as revenue_change,
        (c.revenue - p.prior_revenue) / nullif(p.prior_revenue, 0) * 100 as revenue_pct_change,
        c.orders as current_orders,
        p.prior_orders,
        c.orders - p.prior_orders as orders_change,
        current_timestamp as dbt_updated_at
    from current_period c
    left join prior_period p on c.period = p.period
)

select * from comparison
order by period desc
