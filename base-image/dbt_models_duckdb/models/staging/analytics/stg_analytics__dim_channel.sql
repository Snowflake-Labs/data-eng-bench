{{
    config(
        materialized='view',
        tags=['analytics', 'staging']
    )
}}

-- Staging model for ANALYTICS.DIM_CHANNEL

with source as (
    select * from {{ source('analytics', 'DIM_CHANNEL') }}
),

renamed as (
    select
        channel_key,
        trim(channel_id) as channel_id,
        trim(channel_code) as channel_code,
        trim(channel_name) as channel_name,
        trim(channel_type) as channel_type,
        is_active
    from source
)

select * from renamed
