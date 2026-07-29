{{
    config(
        materialized='view',

        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('customer', 'CUSTOMER_TIER_HISTORY') }}

),

deduplicated AS (
    SELECT
        TIER_HISTORY_ID,
        CUSTOMER_ID,
        PREVIOUS_TIER_ID,
        NEW_TIER_ID,
        CHANGE_REASON,
        EFFECTIVE_DATE,
        POINTS_AT_CHANGE,
        SPEND_AT_CHANGE,
        NOTES,
        CREATED_AT,
        CREATED_BY
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TIER_HISTORY_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(TIER_HISTORY_ID) AS tier_history_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(PREVIOUS_TIER_ID) AS previous_tier_id,
        TRIM(NEW_TIER_ID) AS new_tier_id,
        TRIM(CHANGE_REASON) AS change_reason,
        EFFECTIVE_DATE AS effective_date,
        COALESCE(POINTS_AT_CHANGE, 0) as points_at_change,
        COALESCE(SPEND_AT_CHANGE, 0) as spend_at_change,
        TRIM(NOTES) AS notes,
        CREATED_AT AS created_at,
        TRIM(CREATED_BY) AS created_by
    FROM deduplicated
    WHERE TIER_HISTORY_ID IS NOT NULL
)

SELECT * FROM renamed
