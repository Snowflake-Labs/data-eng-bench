{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.ORDER_NOTES

with source as (
    select * from {{ source('orders', 'ORDER_NOTES') }}
),

renamed as (
    select
        trim(note_id) as note_id,
        trim(order_id) as order_id,
        trim(note_type) as note_type,
        trim(note_text) as note_text,
        is_internal,
        trim(created_by) as created_by,
        created_at
    from source
)

select * from renamed
