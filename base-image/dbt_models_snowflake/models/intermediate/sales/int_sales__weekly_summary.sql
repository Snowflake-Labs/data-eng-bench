{{
    config(
        materialized='view',
        tags=['intermediate', 'sales']
    )
}}

with daily as (
    select * from {{ ref('int_sales__daily_summary') }}
),

weekly as (
    select
        DATE_TRUNC(week, sales_date) as week_start,
        source_system,
        sum(total_orders) as total_orders,
        sum(unique_customers) as total_customers,
        sum(total_revenue) as total_revenue,
        avg(avg_order_value) as avg_order_value
    from daily
    group by DATE_TRUNC(week, sales_date), source_system
)

select * from weekly
