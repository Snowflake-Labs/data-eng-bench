{{
    config(
        materialized='view',
        tags=['marketing', 'staging']
    )
}}

-- Staging model for MARKETING.CAMPAIGN_AUDIENCES

with source as (
    select * from {{ source('marketing', 'CAMPAIGN_AUDIENCES') }}
),

renamed as (
    select
        trim(audience_id) as audience_id,
        trim(campaign_id) as campaign_id,
        trim(segment_id) as segment_id,
        trim(audience_name) as audience_name,
        audience_size,
        created_at
    from source
)

select * from renamed
