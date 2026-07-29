{{
    config(
        materialized='view',

        tags=['staging', 'customer', 'scaled']
    )
}}

-- Simplified staging model for CUSTOMER_TIERS reference table
-- This is a basic lookup table with code, name, and min_value

WITH source AS (
    SELECT * FROM {{ source('customer', 'CUSTOMER_TIERS') }}
),

deduplicated AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TIER_CODE ORDER BY TIER_NAME DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(TIER_CODE) AS tier_code,
        TRIM(TIER_NAME) AS tier_name,
        COALESCE(MIN_SPEND_REQUIRED, 0) AS min_spend_required
    FROM cleaned
    WHERE TIER_CODE IS NOT NULL
)

SELECT * FROM renamed
