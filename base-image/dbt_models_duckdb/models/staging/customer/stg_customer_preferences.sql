{{
    config(
        materialized='view',
        
        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CUSTOMER_PREFERENCES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PREFERENCE_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PREFERENCE_ID) AS preference_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(PREFERENCE_CATEGORY) AS preference_category,
        TRIM(PREFERENCE_KEY) AS preference_key,
        TRIM(PREFERENCE_VALUE) AS preference_value,
        IS_OPTED_IN AS is_opted_in,
        EFFECTIVE_FROM AS effective_from,
        EFFECTIVE_TO AS effective_to,
        TRIM(SOURCE) AS source,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE PREFERENCE_ID IS NOT NULL
)

SELECT * FROM renamed
