{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.RETURN_REASONS

with source as (
    select * from {{ source('orders', 'RETURN_REASONS') }}
),

renamed as (
    select
        trim(reason_id) as reason_id,
        trim(reason_code) as reason_code,
        trim(reason_name) as reason_name,
        trim(reason_description) as reason_description,
        is_active,
        created_at
    from source
)

select * from renamed
