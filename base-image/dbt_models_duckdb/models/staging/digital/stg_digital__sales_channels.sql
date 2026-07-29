{{
    config(
        materialized='view',
        tags=['digital', 'staging']
    )
}}

-- Staging model for DIGITAL.SALES_CHANNELS

with source as (
    select * from {{ source('digital', 'SALES_CHANNELS') }}
),

renamed as (
    select
        trim(channel_id) as channel_id,
        trim(channel_code) as channel_code,
        trim(channel_name) as channel_name,
        trim(channel_type) as channel_type,
        is_active,
        created_at
    from source
)

select * from renamed
