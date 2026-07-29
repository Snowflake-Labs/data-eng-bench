{{
    config(
        materialized='view',
        
        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PRODUCT_ATTRIBUTE_OPTIONS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY OPTION_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(OPTION_ID) AS option_id,
        TRIM(ATTRIBUTE_ID) AS attribute_id,
        TRIM(OPTION_CODE) AS option_code,
        TRIM(OPTION_VALUE) AS option_value,
        TRIM(OPTION_LABEL) AS option_label,
        COALESCE(SORT_ORDER, 0) AS sort_order,
        TRIM(SWATCH_TYPE) AS swatch_type,
        TRIM(SWATCH_VALUE) AS swatch_value,
        IS_DEFAULT AS is_default,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE OPTION_ID IS NOT NULL
)

SELECT * FROM renamed
