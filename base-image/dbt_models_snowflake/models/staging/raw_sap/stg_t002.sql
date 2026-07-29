{{
    config(
        materialized='view',
        unique_key='_batch_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'T002') }}

),

deduplicated AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY _BATCH_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(LANGUAGE_CODE) AS language_code,
        TRIM(LANGUAGE_NAME) AS language_name,
        TRIM(NATIVE_NAME) AS native_name,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) as _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM deduplicated
    WHERE _BATCH_ID IS NOT NULL
)

SELECT * FROM renamed
