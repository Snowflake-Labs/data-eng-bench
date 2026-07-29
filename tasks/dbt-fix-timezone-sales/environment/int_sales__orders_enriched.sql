{{
    config(
        materialized='view',
        tags=['intermediate', 'sales']
    )
}}

{% set clean_currency = "regexp_replace(CAST(%s AS VARCHAR), '[^0-9.-]', '', 'g')::decimal(18,2)" %}

with sap_orders as (

    select
        order_id,
        order_number,
        customer_id,
        order_type,
        'SAP' as source_system,
        currency_code,
        exchange_rate,
        {{ clean_currency % 'subtotal' }} as subtotal,
        {{ clean_currency % 'discount_total' }} as discount_total,
        {{ clean_currency % 'shipping_total' }} as shipping_total,
        {{ clean_currency % 'tax_total' }} as tax_total,
        {{ clean_currency % 'grand_total' }} as grand_total,
        status,
        payment_status,
        fulfillment_status,
        TRY_CASE(ordered_at AS timestamp) as ordered_at,
        TRY_CASE(shipped_at AS timestamp) as shipped_at,
        TRY_CASE(delivered_at AS timestamp) as delivered_at,
        TRY_CASE(cancelled_at AS timestamp) as cancelled_at,    
    from {{ ref('stg_sap__vbak') }}

),

pos_orders as (

    select
        order_id,
        order_number,
        customer_id,
        order_type,
        'POS' as source_system,
        currency_code,
        exchange_rate,
        {{ clean_currency % 'subtotal' }} as subtotal,
        {{ clean_currency % 'discount_total' }} as discount_total,
        {{ clean_currency % 'shipping_total' }} as shipping_total,
        {{ clean_currency % 'tax_total' }} as tax_total,
        {{ clean_currency % 'grand_total' }} as grand_total,
        status,
        payment_status,
        fulfillment_status,
        {{ parse_timestamp % ('ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at', 'ordered_at') }} as ordered_at,
        {{ parse_timestamp % ('shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at', 'shipped_at') }} as shipped_at,
        {{ parse_timestamp % ('delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at', 'delivered_at') }} as delivered_at,
        {{ parse_timestamp % ('cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at', 'cancelled_at') }} as cancelled_at
    from {{ ref('stg_pos__transactions') }}

),

all_orders as (

    select * from sap_orders
    union all
    select * from pos_orders

),

final as (

    select
        order_id,
        order_number,
        customer_id,
        order_type,
        source_system,
        currency_code,
        exchange_rate,

        -- Order amounts
        subtotal,
        discount_total,
        shipping_total,
        tax_total,
        grand_total,

        -- Calculated fields
        (subtotal - discount_total) as net_subtotal,
        case
            when subtotal > 0 then (discount_total / subtotal)
            else 0
        end as discount_rate,

        -- Status fields
        status,
        payment_status,
        fulfillment_status,

        -- Timestamps
        ordered_at,
        shipped_at,
        delivered_at,
        cancelled_at,

        -- Derived flags
        case
            when cancelled_at is not null then true
            else false
        end as is_cancelled,

        case
            when delivered_at is not null then true
            else false
        end as is_delivered,

        -- Calculate fulfillment time in days
        case
            when delivered_at is not null and ordered_at is not null
            then date_diff('day', ordered_at, delivered_at)
            else null
        end as days_to_fulfill

    from all_orders

)

select * from final