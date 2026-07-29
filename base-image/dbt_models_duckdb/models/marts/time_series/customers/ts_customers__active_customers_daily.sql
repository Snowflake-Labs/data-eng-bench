{{
    config(
        materialized='view',
        tags=['time_series', 'customers', 'daily']
    )
}}

/*
 * Time Series: Active Customers - Daily
 * Counts unique active customers by daily
 */

with customer_orders as (
    select
        order_date,
        customer_id
    from {{ ref('fct_sales') }}
    where is_cancelled = false
),

aggregated as (
    select
        date_trunc('day', order_date) as period_start,
        count(distinct customer_id) as active_customers,
        current_timestamp as dbt_updated_at
    from customer_orders
    group by date_trunc('day', order_date)
)

select * from aggregated
order by period_start
