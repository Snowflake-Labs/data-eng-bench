{{
    config(
        materialized='view',
        tags=['intermediate', 'sales']
    )
}}

with daily as (
    select * from {{ ref('int_sales__daily_summary') }}
),

monthly as (
    select
        date_trunc('month', sales_date) as month_start,
        source_system,
        sum(total_orders) as total_orders,
        sum(unique_customers) as total_customers,
        sum(total_revenue) as total_revenue,
        sum(total_discounts) as total_discounts,
        avg(avg_order_value) as avg_order_value
    from daily
    group by date_trunc('month', sales_date), source_system
)

select * from monthly
