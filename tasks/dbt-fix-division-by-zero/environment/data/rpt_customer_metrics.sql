{{
    config(
        materialized='table',
        tags=['mart', 'customer', 'metrics']
    )
}}

/*
    Customer Metrics Report
    Ticket: DATA-6001 - Model producing invalid values
*/

with customer_orders as (
    select
        customer_id,
        count(*) as total_orders,
        sum(grand_total) as total_revenue,
        min(ordered_at) as first_order_date,
        max(ordered_at) as last_order_date,
        count(case when ordered_at >= current_date - interval '30' day then 1 end) as orders_last_30d,
        count(case when ordered_at >= current_date - interval '90' day then 1 end) as orders_last_90d,
        sum(case when ordered_at >= current_date - interval '30' day then grand_total else 0 end) as revenue_last_30d,
        sum(case when ordered_at >= current_date - interval '90' day then grand_total else 0 end) as revenue_last_90d
    from {{ ref('int_sales__orders_enriched') }}
    where status != 'CANCELLED'
    group by customer_id
),

customer_metrics as (
    select
        customer_id,
        total_orders,
        total_revenue,
        first_order_date,
        last_order_date,
        orders_last_30d,
        orders_last_90d,
        revenue_last_30d,
        revenue_last_90d,

        total_revenue / total_orders as avg_order_value,

        total_orders / date_diff('month', first_order_date, current_date) as orders_per_month,

        revenue_last_30d / revenue_last_90d as revenue_velocity_ratio,

        orders_last_30d / orders_last_90d as order_frequency_trend

    from customer_orders
    where total_revenue > 0
)

select * from customer_metrics
