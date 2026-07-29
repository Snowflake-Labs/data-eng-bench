{{
    config(
        materialized='view',
        tags=['analytics', 'staging']
    )
}}

-- Staging model for ANALYTICS.FACT_MARKETING_SPEND

with source as (
    select * from {{ source('analytics', 'FACT_MARKETING_SPEND') }}
),

renamed as (
    select
        trim(spend_key) as spend_key,
        date_key,
        trim(campaign_id) as campaign_id,
        channel_key,
        impressions,
        clicks,
        conversions,
        spend_amount,
        revenue_attributed
    from source
)

select * from renamed
