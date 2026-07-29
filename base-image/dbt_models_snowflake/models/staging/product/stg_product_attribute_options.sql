{{
    config(
        materialized='view',

        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('product', 'PRODUCT_ATTRIBUTE_OPTIONS') }}

),

deduplicated AS (
    SELECT
        OPTION_ID,
        ATTRIBUTE_ID,
        OPTION_CODE,
        OPTION_VALUE,
        OPTION_LABEL,
        SORT_ORDER,
        SWATCH_TYPE,
        SWATCH_VALUE,
        IS_DEFAULT,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY OPTION_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
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
    FROM deduplicated
    WHERE OPTION_ID IS NOT NULL
)

SELECT * FROM renamed
