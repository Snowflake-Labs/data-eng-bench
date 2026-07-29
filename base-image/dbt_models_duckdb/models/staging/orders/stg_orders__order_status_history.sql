{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.ORDER_STATUS_HISTORY

with source as (
    select * from {{ source('orders', 'ORDER_STATUS_HISTORY') }}
),

renamed as (
    select
        trim(history_id) as history_id,
        trim(order_id) as order_id,
        trim(old_status) as old_status,
        trim(new_status) as new_status,
        trim(changed_by) as changed_by,
        trim(change_reason) as change_reason,
        trim(notes) as notes,
        changed_at
    from source
)

select * from renamed
