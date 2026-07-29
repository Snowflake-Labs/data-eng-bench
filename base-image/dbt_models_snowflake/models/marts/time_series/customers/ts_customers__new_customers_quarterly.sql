{{
    config(
        materialized='view',
        tags=['time_series', 'customers', 'quarterly']
    )
}}

/*
 * Time Series: New Customers - Quarterly
 * Counts new customer acquisitions by quarterly
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
        DATE_TRUNC(quarter, first_order_date) as period_start,
        count(distinct customer_id) as new_customers,
        current_timestamp as dbt_updated_at
    from first_orders
    group by DATE_TRUNC(quarter, first_order_date)
)

select * from aggregated
order by period_start
