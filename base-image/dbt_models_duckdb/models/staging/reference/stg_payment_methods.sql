{{
    config(
        materialized='view',

        tags=['staging', 'reference', 'scaled']
    )
}}

-- Simplified staging model for PAYMENT_METHODS reference table
-- This is a basic lookup table with code, name, and is_electronic flag

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PAYMENT_METHODS') }}
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
        TRIM(code) AS payment_method_code,
        TRIM(name) AS payment_method_name,
        is_electronic
    FROM cleaned
    WHERE code IS NOT NULL
)

SELECT * FROM renamed
