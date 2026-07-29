{{
    config(
        materialized='view',

        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('product', 'BRANDS') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY BRAND_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        BRAND_ID,
        BRAND_CODE,
        BRAND_NAME,
        BRAND_DESCRIPTION,
        BRAND_LOGO_URL,
        BRAND_WEBSITE,
        PARENT_BRAND_ID,
        IS_PRIVATE_LABEL,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT
    FROM deduplicated
    WHERE row_num = 1
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
