{{
    config(
        materialized='view',
        tags=['time_series', 'customers', 'weekly']
    )
}}

/*
 * Time Series: Active Customers - Weekly
 * Counts unique active customers by weekly
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
        date_trunc('week', order_date) as period_start,
        count(distinct customer_id) as active_customers,
        current_timestamp as dbt_updated_at
    from customer_orders
    group by date_trunc('week', order_date)
)

select * from aggregated
order by period_start
