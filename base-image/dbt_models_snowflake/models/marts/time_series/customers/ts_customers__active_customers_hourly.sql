{{
    config(
        materialized='view',
        tags=['time_series', 'customers', 'hourly']
    )
}}

/*
 * Time Series: Active Customers - Hourly
 * Counts unique active customers by hourly
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
        DATE_TRUNC(hour, order_date) as period_start,
        count(distinct customer_id) as active_customers,
        current_timestamp as dbt_updated_at
    from customer_orders
    group by DATE_TRUNC(hour, order_date)
)

select * from aggregated
order by period_start
