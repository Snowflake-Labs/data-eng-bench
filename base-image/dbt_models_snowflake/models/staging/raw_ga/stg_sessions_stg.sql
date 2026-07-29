{{
    config(
        materialized='view',
        unique_key='session_id',
        tags=['staging', 'raw_ga', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_ga', 'sessions_stg') }}

),

deduplicated AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY SESSION_ID ORDER BY created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(SESSION_ID) AS session_id,
        TRIM(VISITOR_ID) AS visitor_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(CHANNEL_ID) AS channel_id,
        TRIM(SESSION_START) AS session_start,
        TRIM(SESSION_END) AS session_end,
        COALESCE(DURATION_SECONDS, 0) as duration_seconds,
        COALESCE(PAGE_VIEWS, 0) as page_views,
        TRIM(LANDING_PAGE) AS landing_page,
        TRIM(EXIT_PAGE) AS exit_page,
        TRIM(REFERRER) AS referrer,
        TRIM(UTM_SOURCE) AS utm_source,
        TRIM(UTM_MEDIUM) AS utm_medium,
        TRIM(UTM_CAMPAIGN) AS utm_campaign,
        TRIM(DEVICE_TYPE) AS device_type,
        TRIM(BROWSER) AS browser,
        TRIM(OS) AS os,
        TRIM(IP_ADDRESS) AS ip_address,
        TRIM(COUNTRY) AS country,
        IS_CONVERTED AS is_converted
    FROM cleaned
    WHERE SESSION_ID IS NOT NULL
)

SELECT * FROM renamed
