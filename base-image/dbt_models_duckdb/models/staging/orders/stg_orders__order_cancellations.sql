{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.ORDER_CANCELLATIONS

with source as (
    select * from {{ source('orders', 'ORDER_CANCELLATIONS') }}
),

renamed as (
    select
        trim(cancellation_id) as cancellation_id,
        trim(order_id) as order_id,
        trim(reason_code) as reason_code,
        trim(reason_text) as reason_text,
        trim(cancelled_by) as cancelled_by,
        cancelled_at,
        refund_amount
    from source
)

select * from renamed
