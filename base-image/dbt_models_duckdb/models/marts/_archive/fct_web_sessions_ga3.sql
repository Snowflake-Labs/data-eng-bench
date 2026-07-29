/*
================================================================================
LEGACY: Google Analytics 3 (Universal Analytics) Sessions
================================================================================
GA3 was sunset by Google on July 1, 2023.
This model has been producing empty results for 18 months.
But it still runs every night.

Nobody noticed because:
1. The model doesn't error (just returns 0 rows)
2. Dashboard that used it was also deprecated
3. No monitoring on row counts

This is a cautionary tale about monitoring.
================================================================================
*/

{{
    config(
        enabled=false,
        materialized='table',
        tags=['legacy', 'ga3', 'sunset', 'empty_results'],
        meta={
            'owner': 'unassigned',
            'status': 'PRODUCING_EMPTY_RESULTS',
            'sunset_date': '2023-07-01',
            'source': 'GA3 (Universal Analytics) - DISCONTINUED'
        }
    )
}}

-- GA3 has been sunset since 2023-07-01
-- This model returns 0 rows but nobody noticed
-- TODO: Add row count monitoring to all models

SELECT
    session_id,
    user_id,
    session_start,
    session_end,
    page_views,
    session_duration_seconds,
    bounce_flag,
    traffic_source,
    traffic_medium,
    traffic_campaign,
    device_category,
    browser,
    country,
    region,
    city

FROM {{ source('google_analytics_3', 'sessions') }}  -- This source no longer receives data
WHERE session_start >= CURRENT_DATE - 30

-- Result: 0 rows since 2023-07-01
-- Model runs successfully every night
-- Nobody knows this is broken
