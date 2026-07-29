{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.RETURN_LINES

with source as (
    select * from {{ source('orders', 'RETURN_LINES') }}
),

renamed as (
    select
        trim(return_line_id) as return_line_id,
        trim(return_id) as return_id,
        trim(order_line_id) as order_line_id,
        quantity_returned,
        trim(reason_id) as reason_id,
        trim(condition) as condition,
        refund_amount,
        created_at
    from source
)

select * from renamed
