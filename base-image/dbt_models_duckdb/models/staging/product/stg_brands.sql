{{
    config(
        materialized='view',
        
        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'BRANDS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY BRAND_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(BRAND_ID) AS brand_id,
        TRIM(BRAND_CODE) AS brand_code,
        TRIM(BRAND_NAME) AS brand_name,
        TRIM(BRAND_DESCRIPTION) AS brand_description,
        TRIM(BRAND_LOGO_URL) AS brand_logo_url,
        TRIM(BRAND_WEBSITE) AS brand_website,
        TRIM(PARENT_BRAND_ID) AS parent_brand_id,
        IS_PRIVATE_LABEL AS is_private_label,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE BRAND_ID IS NOT NULL
)

SELECT * FROM renamed
