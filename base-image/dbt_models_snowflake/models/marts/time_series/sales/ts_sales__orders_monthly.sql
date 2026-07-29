{{
    config(
        materialized='view',
        tags=['time_series', 'sales', 'monthly']
    )
}}

/*
 * Time Series: Orders - Monthly
 * Aggregates sales orders by monthly
 */

with sales_data as (
    select
        order_date,
        order_id,
        customer_id,
        line_total as amount,
        quantity_ordered as units,
        discount_amount
    from {{ ref('fct_sales') }}
    where order_date is not null
),

aggregated as (
    select
        DATE_TRUNC('month', order_date) as period_start,
        count(distinct order_id) as order_count,
        count(distinct customer_id) as customer_count,
        sum(amount) as total_revenue,
        sum(units) as total_units,
        sum(discount_amount) as total_discount,
        avg(amount) as avg_amount,
        current_timestamp as dbt_updated_at
    from sales_data
    group by DATE_TRUNC('month', order_date)
)

select * from aggregated
order by period_start
