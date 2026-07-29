{{
    config(
        materialized='view',
        tags=['digital', 'staging']
    )
}}

-- Staging model for DIGITAL.CHANNEL_CONFIGURATIONS

with source as (
    select * from {{ source('digital', 'CHANNEL_CONFIGURATIONS') }}
),

renamed as (
    select
        trim(config_id) as config_id,
        trim(channel_id) as channel_id,
        trim(config_key) as config_key,
        trim(config_value) as config_value,
        created_at
    from source
)

select * from renamed
