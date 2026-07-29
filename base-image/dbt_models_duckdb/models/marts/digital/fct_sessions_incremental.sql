/*
================================================================================
fct_sessions_incremental - Web Sessions Fact (Incremental)
================================================================================
Incrementally builds the web sessions fact table from GA4 events.

This model handles the transition from GA3 (UA) to GA4. The data formats
are completely different, which made this migration... interesting.

MIGRATION NOTES (GA3 -> GA4):
- GA4 sends events, not sessions - we have to sessionize ourselves
- Session timeout changed from 30 min (GA3) to configurable (GA4)
- User IDs work differently in GA4
- Attribution data structure completely changed
- Took 2 months longer than estimated

INCIDENT HISTORY:
- 2024-03-01: GA4 migration go-live
  "Everything is fine." - Famous last words.

- 2024-03-05: P1 - Session counts dropped 40%
  Root cause: Sessionization logic didn't handle midnight crossings
  Fix: Added date boundary handling
  Duration: 8 hours
  Ticket: INC-2024-0305

- 2024-03-15: P2 - Conversion attribution broken
  Root cause: UTM parameters parsed differently in GA4
  Fix: Added compatibility layer for UTM parsing
  Ticket: INC-2024-0315

- 2024-05-20: P2 - Bot traffic causing session explosion
  Root cause: GA4 doesn't filter bots the same way
  Fix: Added user_agent filtering
  Ticket: INC-2024-0520

- 2024-08-01: P3 - PageView counts don't match GA4 UI
  Root cause: We count differently than Google (by design)
  Resolution: Documented as expected behavior
  Ticket: DATA-3456 (closed as won't fix)

Code Review Comments:
- Sarah (2024-02-28): "Are we ready for the GA4 migration?"
- Marcus (2024-02-28): "Totally ready. What could go wrong?"
- Sarah (2024-03-05): "I'm never trusting you again."
- Marketing (2024-03-10): "Why don't the numbers match GA4 UI?"
- Marcus (2024-03-10): "Because GA4 is wrong. We're right. Trust us."
================================================================================
*/

-- Disabled: stg_ga__events schema changed - missing user_agent, device_category, etc
{{
    config(
        enabled=false,
        materialized='incremental',
        unique_key='session_id',
        incremental_strategy='merge',
        merge_update_columns=['session_end', 'page_views', 'events_count', 'is_converted', 'conversion_value', 'updated_at', 'dbt_updated_at'],
        on_schema_change='append_new_columns',
        cluster_by=['session_date', 'traffic_source'],
        tags=['incremental', 'digital', 'ga4', 'sessions'],
        meta={
            'owner': 'digital-analytics@company.com',
            'sla': '8am UTC',
            'estimated_runtime_minutes': 35,
            'snowflake_warehouse': 'TRANSFORM_L',
            'ga4_migrated': '2024-03-01',
            'known_discrepancy': 'Numbers will not match GA4 UI exactly'
        }
    )
}}

{% set session_timeout_minutes = 30 %}
{% set lookback_hours = 6 %}  -- Sessions can span midnight

WITH events AS (

    SELECT
        event_id,
        session_id,
        visitor_id,
        customer_id,
        event_type,
        event_name,
        event_timestamp,
        page_url,
        page_title,
        referrer,
        utm_source,
        utm_medium,
        utm_campaign,
        utm_term,
        utm_content,
        device_type,
        browser,
        os,
        country,
        region,
        city,
        -- GA4 specific fields
        engagement_time_msec,
        is_engaged_session,
        -- Conversion tracking
        CASE
            WHEN event_name IN ('purchase', 'begin_checkout', 'add_to_cart') THEN 1
            ELSE 0
        END AS is_conversion_event,
        COALESCE(TRY_CAST(event_value AS DECIMAL(18,2)), 0) AS event_value,
        user_agent,
        _loaded_at

    FROM {{ ref('stg_ga__events') }}

    WHERE 1=1  -- Base filter for proper AND clause handling
    {% if is_incremental() %}
    AND event_timestamp >= CURRENT_TIMESTAMP - INTERVAL '{{ lookback_hours }} hours'
    {% endif %}

    -- Bot filtering (INC-2024-0520)
    AND NOT (
        LOWER(user_agent) LIKE '%bot%'
        OR LOWER(user_agent) LIKE '%crawler%'
        OR LOWER(user_agent) LIKE '%spider%'
        OR LOWER(user_agent) LIKE '%googlebot%'
        OR LOWER(user_agent) LIKE '%bingbot%'
        OR LOWER(user_agent) LIKE '%yandex%'
        OR user_agent IS NULL
    )

),

-- Sessionization logic (we build sessions from events)
-- GA4 sends session_id but it's not always reliable
sessionized AS (

    SELECT
        COALESCE(
            session_id,
            -- Fallback: create our own session_id
            MD5(visitor_id || '|' || DATE_TRUNC('hour', event_timestamp)::VARCHAR)
        ) AS session_id,
        visitor_id,
        customer_id,
        event_id,
        event_type,
        event_name,
        event_timestamp,
        page_url,
        page_title,
        referrer,
        utm_source,
        utm_medium,
        utm_campaign,
        utm_term,
        utm_content,
        device_type,
        browser,
        os,
        country,
        region,
        city,
        engagement_time_msec,
        is_engaged_session,
        is_conversion_event,
        event_value,
        _loaded_at

    FROM events

),

-- Aggregate to session level
session_aggregates AS (

    SELECT
        session_id,
        MIN(visitor_id) AS visitor_id,
        -- Take the first non-null customer_id (user might log in mid-session)
        COALESCE(
            MIN(CASE WHEN customer_id IS NOT NULL THEN customer_id END),
            NULL
        ) AS customer_id,

        -- Timing
        MIN(event_timestamp) AS session_start,
        MAX(event_timestamp) AS session_end,
        DATE(MIN(event_timestamp)) AS session_date,
        DATEDIFF('second', MIN(event_timestamp), MAX(event_timestamp)) AS duration_seconds,

        -- Engagement
        COUNT(*) AS events_count,
        COUNT(CASE WHEN event_type = 'page_view' THEN 1 END) AS page_views,
        SUM(engagement_time_msec) / 1000.0 AS total_engagement_seconds,

        -- First/Last page (for funnel analysis)
        MIN(CASE WHEN event_type = 'page_view' THEN page_url END) AS landing_page,
        MAX(CASE WHEN event_type = 'page_view' THEN page_url END) AS exit_page,

        -- Attribution (first-touch)
        MIN(referrer) AS referrer,
        MIN(utm_source) AS utm_source,
        MIN(utm_medium) AS utm_medium,
        MIN(utm_campaign) AS utm_campaign,
        MIN(utm_term) AS utm_term,
        MIN(utm_content) AS utm_content,

        -- Device/Geo (mode would be better but MIN is faster)
        MIN(device_type) AS device_type,
        MIN(browser) AS browser,
        MIN(os) AS os,
        MIN(country) AS country,
        MIN(region) AS region,
        MIN(city) AS city,

        -- Conversions
        MAX(is_conversion_event) AS is_converted,
        SUM(CASE WHEN is_conversion_event = 1 THEN event_value ELSE 0 END) AS conversion_value,

        -- Metadata
        MAX(_loaded_at) AS _loaded_at

    FROM sessionized
    GROUP BY session_id

),

-- Classify traffic source (Marketing always wants this)
with_traffic_classification AS (

    SELECT
        sa.*,

        -- Traffic source classification
        CASE
            WHEN utm_source IS NOT NULL THEN
                CASE
                    WHEN LOWER(utm_medium) IN ('cpc', 'ppc', 'paid') THEN 'Paid Search'
                    WHEN LOWER(utm_medium) IN ('display', 'banner', 'cpm') THEN 'Display'
                    WHEN LOWER(utm_medium) = 'email' THEN 'Email'
                    WHEN LOWER(utm_medium) IN ('social', 'social-media') THEN 'Paid Social'
                    WHEN LOWER(utm_medium) = 'affiliate' THEN 'Affiliate'
                    ELSE 'Other Campaigns'
                END
            WHEN referrer IS NULL OR referrer = '' THEN 'Direct'
            WHEN referrer LIKE '%google%' OR referrer LIKE '%bing%' OR referrer LIKE '%yahoo%' THEN 'Organic Search'
            WHEN referrer LIKE '%facebook%' OR referrer LIKE '%instagram%' OR referrer LIKE '%twitter%' OR referrer LIKE '%linkedin%' THEN 'Organic Social'
            ELSE 'Referral'
        END AS traffic_source,

        -- Bounce definition: single page view, less than 10 seconds
        CASE
            WHEN page_views = 1 AND duration_seconds < 10 THEN TRUE
            ELSE FALSE
        END AS is_bounce,

        -- Engaged session (GA4 definition: 10+ seconds OR 2+ pageviews OR conversion)
        CASE
            WHEN duration_seconds >= 10 OR page_views >= 2 OR is_converted = 1 THEN TRUE
            ELSE FALSE
        END AS is_engaged

    FROM session_aggregates sa

)

SELECT
    -- Primary key
    session_id,

    -- User identification
    visitor_id,
    customer_id,

    -- Timing
    session_start,
    session_end,
    session_date,
    EXTRACT(HOUR FROM session_start) AS session_hour,
    EXTRACT(DAYOFWEEK FROM session_date) AS session_day_of_week,
    duration_seconds,

    -- Engagement metrics
    events_count,
    page_views,
    total_engagement_seconds,
    is_bounce,
    is_engaged,

    -- Navigation
    landing_page,
    exit_page,

    -- Attribution
    referrer,
    utm_source,
    utm_medium,
    utm_campaign,
    utm_term,
    utm_content,
    traffic_source,

    -- Device/Geo
    device_type,
    browser,
    os,
    country,
    region,
    city,

    -- Conversions
    is_converted,
    conversion_value,

    -- Metadata
    _loaded_at,
    CURRENT_TIMESTAMP AS dbt_updated_at,
    '{{ invocation_id }}' AS _dbt_invocation_id

FROM with_traffic_classification
