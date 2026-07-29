{{
    config(
        materialized='view',
        tags=['kpi', 'sales_kpis']
    )
}}

with customer_revenue as (
    select
        customer_id,
        sum(line_total) as total_revenue
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by customer_id
)

select
    'Revenue Per Customer' as kpi_name,
    current_date as period,
    round(avg(total_revenue), 2) as avg_revenue_per_customer,
    round(sum(total_revenue), 2) as total_revenue,
    count(distinct customer_id) as customer_count,
    current_timestamp as dbt_updated_at
from customer_revenue
