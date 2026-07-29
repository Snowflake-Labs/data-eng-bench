{{
    config(
        materialized='view',
        
        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'TAX_RATES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY TAX_RATE_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(TAX_RATE_ID) AS tax_rate_id,
        TRIM(TAX_CODE) AS tax_code,
        TRIM(TAX_NAME) AS tax_name,
        TRIM(TAX_TYPE) AS tax_type,
        RATE AS rate,
        TRIM(COUNTRY_CODE) AS country_code,
        TRIM(STATE_CODE) AS state_code,
        EFFECTIVE_FROM AS effective_from,
        EFFECTIVE_TO AS effective_to,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE TAX_RATE_ID IS NOT NULL
)

SELECT * FROM renamed
