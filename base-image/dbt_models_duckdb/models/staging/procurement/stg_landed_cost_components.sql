{{
    config(
        materialized='view',
        
        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'LANDED_COST_COMPONENTS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY COMPONENT_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(COMPONENT_ID) AS component_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(COMPONENT_TYPE) AS component_type,
        AMOUNT AS amount,
        TRIM(CURRENCY_CODE) AS currency_code,
        EFFECTIVE_FROM AS effective_from,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE COMPONENT_ID IS NOT NULL
)

SELECT * FROM renamed
