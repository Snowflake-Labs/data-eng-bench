{{
    config(
        materialized='view',

        tags=['staging', 'product', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('product', 'PRODUCT_ATTRIBUTES') }}

),

deduplicated AS (
    SELECT
        ATTRIBUTE_ID,
        ATTRIBUTE_CODE,
        ATTRIBUTE_NAME,
        ATTRIBUTE_DESCRIPTION,
        ATTRIBUTE_TYPE,
        DATA_TYPE,
        IS_VARIANT_ATTRIBUTE,
        IS_FILTERABLE,
        IS_SEARCHABLE,
        IS_COMPARABLE,
        IS_REQUIRED,
        DEFAULT_VALUE,
        VALIDATION_REGEX,
        MIN_VALUE,
        MAX_VALUE,
        DISPLAY_ORDER,
        ATTRIBUTE_GROUP,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ATTRIBUTE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(ATTRIBUTE_ID) AS attribute_id,
        TRIM(ATTRIBUTE_CODE) AS attribute_code,
        TRIM(ATTRIBUTE_NAME) AS attribute_name,
        TRIM(ATTRIBUTE_DESCRIPTION) AS attribute_description,
        TRIM(ATTRIBUTE_TYPE) AS attribute_type,
        TRIM(DATA_TYPE) AS data_type,
        IS_VARIANT_ATTRIBUTE AS is_variant_attribute,
        IS_FILTERABLE AS is_filterable,
        IS_SEARCHABLE AS is_searchable,
        IS_COMPARABLE AS is_comparable,
        IS_REQUIRED AS is_required,
        TRIM(DEFAULT_VALUE) AS default_value,
        TRIM(VALIDATION_REGEX) AS validation_regex,
        COALESCE(MIN_VALUE, 0) AS min_value,
        COALESCE(MAX_VALUE, 0) AS max_value,
        COALESCE(DISPLAY_ORDER, 0) AS display_order,
        TRIM(ATTRIBUTE_GROUP) AS attribute_group,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM deduplicated
    WHERE ATTRIBUTE_ID IS NOT NULL
)

SELECT * FROM renamed
