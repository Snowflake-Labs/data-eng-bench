{{
    config(
        materialized='view',
        
        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PRODUCT_TAGS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY TAG_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(TAG_ID) AS tag_id,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(TAG_NAME) AS tag_name,
        TRIM(TAG_TYPE) AS tag_type,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE TAG_ID IS NOT NULL
)

SELECT * FROM renamed
