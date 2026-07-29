{{
    config(
        materialized='view',
        tags=['intermediate', 'sales']
    )
}}

with orders as (
    select * from {{ ref('int_sales__orders_enriched') }}
),

daily_metrics as (
    select
        date(ordered_at) as sales_date,
        source_system,
        currency_code,
        count(distinct order_id) as total_orders,
        count(distinct customer_id) as unique_customers,
        sum(grand_total) as total_revenue,
        sum(discount_total) as total_discounts,
        sum(tax_total) as total_tax,
        avg(grand_total) as avg_order_value,
        count(case when is_cancelled then 1 end) as cancelled_orders,
        count(case when is_delivered then 1 end) as delivered_orders
    from orders
    group by date(ordered_at), source_system, currency_code
)

select * from daily_metrics
