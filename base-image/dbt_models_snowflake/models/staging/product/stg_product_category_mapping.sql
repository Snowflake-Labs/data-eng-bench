{{
    config(
        materialized='view',

        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('product', 'PRODUCT_CATEGORY_MAPPING') }}

),

deduplicated AS (
    SELECT
        MAPPING_ID,
        PRODUCT_ID,
        CATEGORY_ID,
        IS_PRIMARY,
        SORT_ORDER,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY MAPPING_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(MAPPING_ID) AS mapping_id,
        TRIM(PRODUCT_ID) AS product_id,
        TRIM(CATEGORY_ID) AS category_id, IS_PRIMARY as is_primary,
        COALESCE(SORT_ORDER, 0) as sort_order,
        CREATED_AT AS created_at
    FROM deduplicated
    WHERE MAPPING_ID IS NOT NULL
)

SELECT * FROM renamed
