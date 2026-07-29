{{
    config(
        materialized='view',
        tags=['marketing', 'staging']
    )
}}

-- Staging model for MARKETING.CAMPAIGN_CHANNELS

with source as (
    select * from {{ source('marketing', 'CAMPAIGN_CHANNELS') }}
),

renamed as (
    select
        trim(channel_mapping_id) as channel_mapping_id,
        trim(campaign_id) as campaign_id,
        trim(channel_type) as channel_type,
        allocated_budget,
        created_at
    from source
)

select * from renamed
