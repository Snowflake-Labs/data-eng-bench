{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.CHANNELS

with source as (
    select * from {{ source('orders', 'CHANNELS') }}
),

renamed as (
    select
        trim(channel_id) as channel_id,
        trim(channel_code) as channel_code,
        trim(channel_name) as channel_name,
        trim(channel_type) as channel_type,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
