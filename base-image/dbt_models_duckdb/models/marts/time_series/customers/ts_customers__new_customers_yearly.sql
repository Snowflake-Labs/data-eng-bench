{{
    config(
        materialized='view',
        tags=['time_series', 'customers', 'yearly']
    )
}}

/*
 * Time Series: New Customers - Yearly
 * Counts new customer acquisitions by yearly
 */

with first_orders as (
    select
        customer_id,
        min(order_date) as first_order_date
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by customer_id
),

aggregated as (
    select
        date_trunc('year', first_order_date) as period_start,
        count(distinct customer_id) as new_customers,
        current_timestamp as dbt_updated_at
    from first_orders
    group by date_trunc('year', first_order_date)
)

select * from aggregated
order by period_start
