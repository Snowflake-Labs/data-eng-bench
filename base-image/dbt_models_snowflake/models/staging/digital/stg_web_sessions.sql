{{
    config(
        materialized='view',

        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('digital', 'WEB_SESSIONS') }}

),

deduplicated AS (
    SELECT
        SESSION_ID,
        VISITOR_ID,
        CUSTOMER_ID,
        CHANNEL_ID,
        SESSION_START,
        SESSION_END,
        DURATION_SECONDS,
        PAGE_VIEWS,
        LANDING_PAGE,
        EXIT_PAGE,
        REFERRER,
        UTM_SOURCE,
        UTM_MEDIUM,
        UTM_CAMPAIGN,
        DEVICE_TYPE,
        BROWSER,
        OS,
        IP_ADDRESS,
        COUNTRY,
        IS_CONVERTED
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
        SESSION_START AS session_start,
        SESSION_END AS session_end,
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
