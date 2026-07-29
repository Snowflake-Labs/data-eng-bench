{{
    config(
        materialized='view',
        
        tags=['staging', 'raw_legacy', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'ITMATTR_HIST') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY ATTRIBUTE_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
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
        TRIM(MIN_VALUE) AS min_value,
        TRIM(MAX_VALUE) AS max_value,
        COALESCE(DISPLAY_ORDER, 0) AS display_order,
        TRIM(ATTRIBUTE_GROUP) AS attribute_group,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE ATTRIBUTE_ID IS NOT NULL
)

SELECT * FROM renamed
