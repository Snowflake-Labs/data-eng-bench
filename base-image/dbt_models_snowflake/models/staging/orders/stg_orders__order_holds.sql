{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.ORDER_HOLDS

with source as (
    select * from {{ source('orders', 'ORDER_HOLDS') }}
),

renamed as (
    select
        trim(hold_id) as hold_id,
        trim(order_id) as order_id,
        trim(hold_type) as hold_type,
        trim(hold_reason) as hold_reason,
        trim(hold_status) as hold_status,
        trim(placed_by) as placed_by,
        placed_at,
        trim(released_by) as released_by,
        released_at,
        trim(notes) as notes
    from source
)

select * from renamed
