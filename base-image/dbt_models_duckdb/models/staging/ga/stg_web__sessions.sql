/*
================================================================================
stg_web__sessions - Web Session Staging
================================================================================
Staging model for web session data from Google Analytics.
================================================================================
*/

{{
    config(
        materialized='view',
        tags=['staging', 'web', 'ga']
    )
}}

SELECT
    session_id,
    customer_id,
    visitor_id,
    channel_id,
    session_start,
    session_end,
    landing_page,
    exit_page,
    page_views,
    duration_seconds,
    -- Bounce = single pageview with short duration (industry standard: <15-20 seconds)
    CASE WHEN page_views = 1 AND duration_seconds < 20 THEN TRUE ELSE FALSE END AS is_bounce,
    device_type AS device_category,
    browser,
    os AS operating_system,
    country,
    referrer,
    utm_source,
    utm_medium,
    utm_campaign,
    is_converted,
    order_id,
    created_at,
    _loaded_at
FROM {{ source('ga', 'SESSIONS') }}
