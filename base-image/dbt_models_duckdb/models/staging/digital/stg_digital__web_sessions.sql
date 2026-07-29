{{
    config(
        materialized='view',
        tags=['digital', 'staging']
    )
}}

-- Staging model for DIGITAL.WEB_SESSIONS

with source as (
    select * from {{ source('digital', 'WEB_SESSIONS') }}
),

renamed as (
    select
        trim(session_id) as session_id,
        trim(visitor_id) as visitor_id,
        trim(customer_id) as customer_id,
        trim(channel_id) as channel_id,
        session_start,
        session_end,
        duration_seconds,
        page_views,
        trim(landing_page) as landing_page,
        trim(exit_page) as exit_page,
        trim(referrer) as referrer,
        trim(utm_source) as utm_source,
        trim(utm_medium) as utm_medium,
        trim(utm_campaign) as utm_campaign,
        trim(device_type) as device_type,
        trim(browser) as browser,
        trim(os) as os,
        trim(ip_address) as ip_address,
        trim(country) as country,
        is_converted,
        trim(order_id) as order_id,
        created_at
    from source
)

select * from renamed
