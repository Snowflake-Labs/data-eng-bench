{{
    config(
        materialized='view',

        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('product', 'PRODUCT_TAGS') }}

),

deduplicated AS (
    SELECT
        TAG_ID,
        PRODUCT_ID,
        TAG_NAME,
        TAG_TYPE,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TAG_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(TAG_ID) AS tag_id,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(TAG_NAME) AS tag_name,
        TRIM(TAG_TYPE) AS tag_type,
        CREATED_AT AS created_at
    FROM deduplicated
    WHERE TAG_ID IS NOT NULL
)

SELECT * FROM renamed
