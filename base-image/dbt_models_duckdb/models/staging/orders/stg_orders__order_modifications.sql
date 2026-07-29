{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.ORDER_MODIFICATIONS

with source as (
    select * from {{ source('orders', 'ORDER_MODIFICATIONS') }}
),

renamed as (
    select
        trim(modification_id) as modification_id,
        trim(order_id) as order_id,
        trim(modification_type) as modification_type,
        trim(field_name) as field_name,
        trim(old_value) as old_value,
        trim(new_value) as new_value,
        trim(modified_by) as modified_by,
        modified_at,
        trim(reason) as reason
    from source
)

select * from renamed
