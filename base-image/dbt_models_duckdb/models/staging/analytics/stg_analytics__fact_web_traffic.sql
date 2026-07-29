{{
    config(
        materialized='view',
        tags=['analytics', 'staging']
    )
}}

-- Staging model for ANALYTICS.FACT_WEB_TRAFFIC

with source as (
    select * from {{ source('analytics', 'FACT_WEB_TRAFFIC') }}
),

renamed as (
    select
        trim(traffic_key) as traffic_key,
        date_key,
        time_key,
        customer_key,
        channel_key,
        trim(session_id) as session_id,
        page_views,
        unique_pages,
        session_duration_seconds,
        bounced,
        converted,
        revenue
    from source
)

select * from renamed
