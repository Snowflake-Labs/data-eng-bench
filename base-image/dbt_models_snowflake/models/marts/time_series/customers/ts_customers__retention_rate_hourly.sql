{{
    config(
        materialized='view',
        tags=['time_series', 'customers', 'hourly']
    )
}}

/*
 * Time Series: Retention Rate - Hourly
 */

with customer_data as (
    select
        order_date,
        customer_id,
        line_total
    from {{ ref('fct_sales') }}
    where is_cancelled = false
),

aggregated as (
    select
        DATE_TRUNC(hour, order_date) as period_start,
        count(distinct customer_id) as customer_count,
        sum(line_total) as total_revenue,
        current_timestamp as dbt_updated_at
    from customer_data
    group by DATE_TRUNC(hour, order_date)
)

select * from aggregated
order by period_start
