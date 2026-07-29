{{
    config(
        materialized='view',
        
        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PRODUCT_CATEGORY_MAPPING') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY MAPPING_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(MAPPING_ID) AS mapping_id,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(CATEGORY_ID) AS category_id,
        IS_PRIMARY AS is_primary,
        COALESCE(SORT_ORDER, 0) AS sort_order,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE MAPPING_ID IS NOT NULL
)

SELECT * FROM renamed
