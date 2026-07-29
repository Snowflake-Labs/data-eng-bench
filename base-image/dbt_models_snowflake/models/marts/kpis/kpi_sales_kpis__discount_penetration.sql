{{
    config(
        materialized='view',
        tags=['kpi', 'sales_kpis']
    )
}}

with sales as (
    select
        order_id,
        line_total,
        discount_amount
    from {{ ref('fct_sales') }}
    where is_cancelled = false
)

select
    'Discount Penetration' as kpi_name,
    current_date as period,
    round(100.0 * count(distinct case when discount_amount > 0 then order_id end) / nullif(count(distinct order_id), 0), 2) as discount_penetration_pct,
    round(100.0 * sum(discount_amount) / nullif(sum(line_total + discount_amount), 0), 2) as discount_rate_pct,
    count(distinct case when discount_amount > 0 then order_id end) as orders_with_discount,
    count(distinct order_id) as total_orders,
    current_timestamp as dbt_updated_at
from sales
