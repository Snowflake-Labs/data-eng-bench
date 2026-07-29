{{
    config(
        materialized='view',

        tags=['staging', 'reference', 'scaled']
    )
}}

-- Simplified staging model for PAYMENT_METHODS reference table

WITH source AS (
    SELECT * FROM {{ source('reference', 'PAYMENT_METHODS') }}
),

deduplicated AS (
    SELECT
        PAYMENT_METHOD_CODE,
        PAYMENT_METHOD_NAME,
        ROW_NUMBER() OVER (PARTITION BY PAYMENT_METHOD_CODE ORDER BY PAYMENT_METHOD_NAME DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        PAYMENT_METHOD_CODE,
        PAYMENT_METHOD_NAME
    FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PAYMENT_METHOD_CODE) AS payment_method_code,
        TRIM(PAYMENT_METHOD_NAME) AS payment_method_name
    FROM cleaned
    WHERE PAYMENT_METHOD_CODE IS NOT NULL
)

SELECT * FROM renamed
