{{
    config(
        materialized='view',
        
        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('finance', 'TAX_RATES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY TAX_RATE_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
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
    FROM deduplicated
    WHERE TAX_RATE_ID IS NOT NULL
    QUALIFY row_num = 1
)

SELECT * FROM renamed
