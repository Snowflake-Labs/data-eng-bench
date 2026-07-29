{{
    config(
        materialized='view',
        
        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CUSTOMER_TIER_HISTORY') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY TIER_HISTORY_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(TIER_HISTORY_ID) AS tier_history_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(PREVIOUS_TIER_ID) AS previous_tier_id,
        TRIM(NEW_TIER_ID) AS new_tier_id,
        TRIM(CHANGE_REASON) AS change_reason,
        EFFECTIVE_DATE AS effective_date,
        COALESCE(POINTS_AT_CHANGE, 0) AS points_at_change,
        COALESCE(SPEND_AT_CHANGE, 0) AS spend_at_change,
        TRIM(NOTES) AS notes,
        CREATED_AT AS created_at,
        TRIM(CREATED_BY) AS created_by
    FROM cleaned
    WHERE TIER_HISTORY_ID IS NOT NULL
)

SELECT * FROM renamed
