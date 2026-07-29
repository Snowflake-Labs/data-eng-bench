{{
    config(
        materialized='view',
        tags=['marketing', 'staging']
    )
}}

-- Staging model for MARKETING.CAMPAIGN_PERFORMANCE

with source as (
    select * from {{ source('marketing', 'CAMPAIGN_PERFORMANCE') }}
),

renamed as (
    select
        trim(performance_id) as performance_id,
        trim(campaign_id) as campaign_id,
        metric_date,
        impressions,
        clicks,
        conversions,
        spend,
        revenue,
        created_at
    from source
)

select * from renamed
