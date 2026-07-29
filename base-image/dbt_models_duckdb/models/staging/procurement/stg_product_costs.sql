{{
    config(
        materialized='view',
        
        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PRODUCT_COSTS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY COST_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(COST_ID) AS cost_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(SUPPLIER_ID) AS supplier_id,
        TRIM(COST_TYPE) AS cost_type,
        UNIT_COST AS unit_cost,
        TRIM(CURRENCY_CODE) AS currency_code,
        EFFECTIVE_FROM AS effective_from,
        EFFECTIVE_TO AS effective_to,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE COST_ID IS NOT NULL
)

SELECT * FROM renamed
