{{
    config(
        materialized='view',

        tags=['staging', 'customer', 'scaled']
    )
}}

-- Simplified staging model for CUSTOMER_TIERS reference table
-- This is a basic lookup table with code, name, and min_value

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CUSTOMER_TIERS') }}
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY code ORDER BY name DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(code) AS tier_code,
        TRIM(name) AS tier_name,
        COALESCE(min_value, 0) AS min_spend_required
    FROM cleaned
    WHERE code IS NOT NULL
)

SELECT * FROM renamed
