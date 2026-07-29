{{
    config(
        materialized='view',
        tags=['marketing', 'staging']
    )
}}

-- Staging model for MARKETING.MARKETING_CAMPAIGNS

with source as (
    select * from {{ source('marketing', 'MARKETING_CAMPAIGNS') }}
),

renamed as (
    select
        trim(campaign_id) as campaign_id,
        trim(campaign_code) as campaign_code,
        trim(campaign_name) as campaign_name,
        trim(campaign_type) as campaign_type,
        start_date,
        end_date,
        budget,
        trim(status) as status,
        created_at,
        updated_at
    from source
)

select * from renamed
