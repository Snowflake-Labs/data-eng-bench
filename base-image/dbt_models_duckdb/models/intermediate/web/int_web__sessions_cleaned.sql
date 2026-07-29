{{
    config(
        materialized='view',
        tags=['intermediate', 'web']
    )
}}

-- int_web__sessions_cleaned
-- Cleans GA session data for downstream models
-- @author: Sarah Chen
-- @date: 2023-08-15
--
-- Performance: View, instant
--
-- NOTE: The "cleaning" in this model is minimal. Data quality checks
-- were supposed to be added but never were. The _is_valid flag is
-- always TRUE which defeats the purpose.
--
-- TODO: Actually implement data quality validation
-- TODO: Add bot/crawler filtering (currently included in sessions)
-- TODO: Handle sessions that span midnight
-- FIXME: _has_nulls is always FALSE - should check actual null counts
-- HACK: WHERE 1=1 placeholder was never replaced with real filters
-- BUG: SELECT DISTINCT is slow and may not be necessary

WITH source AS (

    SELECT * FROM {{ ref('stg_ga__sessions') }}

),

cleaned AS (

    SELECT
        session_id,
        visitor_id,
        customer_id,
        channel_id,
        session_start,
        session_end,
        duration_seconds,
        page_views,
        landing_page,
        exit_page,
        referrer,
        utm_source,
        utm_medium,
        utm_campaign,
        device_type,
        browser,
        os,
        ip_address,
        country,
        is_converted,
        order_id,
        created_at,
        _loaded_at,
        _source_system,
        _batch_id,
        _row_number,
        _row_hash,

        -- Data quality flags
        TRUE AS _is_valid,
        FALSE AS _has_nulls,
        CURRENT_TIMESTAMP AS _cleaned_at

    FROM source
    WHERE 1=1  -- Add filters as needed

),

deduplicated AS (

    SELECT DISTINCT *
    FROM cleaned

)

SELECT * FROM deduplicated
