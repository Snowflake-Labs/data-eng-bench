{{
    config(
        materialized='view',
        tags=['time_series', 'customers', 'weekly']
    )
}}

/*
 * Time Series: Churned Customers - Weekly
 * Counts customers who churned (no orders in 90 days) by weekly
 */

with customer_last_order as (
    select
        customer_id,
        max(order_date) as last_order_date
    from {{ ref('fct_sales') }}
    where is_cancelled = false
    group by customer_id
),

churned_by_period as (
    select
        date_trunc('week', (last_order_date + interval '90 day')) as period_start,
        customer_id
    from customer_last_order
    where (last_order_date + interval '90 day') < current_date
),

aggregated as (
    select
        period_start,
        count(distinct customer_id) as churned_customers,
        current_timestamp as dbt_updated_at
    from churned_by_period
    group by period_start
)

select * from aggregated
order by period_start
