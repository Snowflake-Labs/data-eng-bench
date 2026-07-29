{{
    config(
        materialized='view',
        
        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CURRENCY_EXCHANGE_RATES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY RATE_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(RATE_ID) AS rate_id,
        TRIM(FROM_CURRENCY) AS from_currency,
        TRIM(TO_CURRENCY) AS to_currency,
        EXCHANGE_RATE AS exchange_rate,
        EFFECTIVE_DATE AS effective_date,
        TRIM(SOURCE) AS source,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE RATE_ID IS NOT NULL
)

SELECT * FROM renamed
