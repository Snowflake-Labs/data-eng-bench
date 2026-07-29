
{{
    config(
        materialized='table',
        tags=['mart', 'customers', 'core']
    )
}}


with customers as (

    select * from {{ ref('int_customers__unified') }}

),


customer_orders as (

    select
        customer_id,
        count(distinct order_id) as total_orders,
        sum(grand_total) as total_value,
        min(ordered_at) as first_order_date,
        max(ordered_at) as last_order_date,
        avg(grand_total) as avg_order_value
    from {{ ref('int_sales__orders_enriched') }}
    group by customer_id

),

final as (

    select
        -- Primary Key
        c.customer_id,

        -- Customer Attributes
        c.email,
        c.first_name,
        c.last_name,
        c.full_name,
        c.phone,
        c.account_id,
        c.status,
        c.source_system,

        -- Dates
        c.created_at as customer_since,
        c.updated_at as last_updated,
        c.customer_age_days,

        -- Order Metrics
        coalesce(co.total_orders, 0) as total_orders,
        coalesce(co.total_value, 0) as lifetime_value,
        co.first_order_date,
        co.last_order_date,
        coalesce(co.avg_order_value, 0) as avg_order_value,

        -- Calculated Metrics
        case
            when co.last_order_date is not null
            then datediff('day', co.last_order_date, current_timestamp)
            else null
        end as days_since_last_order,

        -- Customer Segmentation
        case
            when coalesce(co.total_orders, 0) = 0 then 'Never Ordered'
            when coalesce(co.total_orders, 0) = 1 then 'One-time Buyer'
            when coalesce(co.total_orders, 0) between 2 and 5 then 'Occasional Buyer'
            when coalesce(co.total_orders, 0) between 6 and 10 then 'Regular Buyer'
            else 'Loyal Customer'
        end as customer_segment,

        case
            when coalesce(co.total_value, 0) >= {{ var('customer_value_vip_threshold', 10000) }} then 'VIP'
            when coalesce(co.total_value, 0) >= {{ var('customer_value_high_threshold', 5000) }} then 'High Value'
            when coalesce(co.total_value, 0) >= {{ var('customer_value_medium_threshold', 1000) }} then 'Medium Value'
            when coalesce(co.total_value, 0) > 0 then 'Low Value'
            else 'No Value'
        end as value_segment,

        -- Flags
        c.is_active,
        c.has_email,
        c.has_phone,
        case
            when co.total_orders > 0 then true
            else false
        end as has_ordered,

        -- Metadata
        current_timestamp as dbt_updated_at

    from customers c
    left join customer_orders co
        on c.customer_id = co.customer_id

)

select * from final
