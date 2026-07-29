{{
    config(
        materialized='view',

        tags=['staging', 'raw_legacy', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_legacy', 'stscod') }}

),

cleaned AS (
    SELECT
        STATUS_CODE_ID,
        ENTITY_TYPE,
        STATUS_CODE,
        STATUS_NAME,
        STATUS_DESCRIPTION,
        DISPLAY_ORDER,
        IS_TERMINAL,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT,
        _LOADED_AT,
        _SOURCE_SYSTEM,
        _BATCH_ID,
        _ROW_NUMBER,
        _ROW_HASH
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY STATUS_CODE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(STATUS_CODE_ID) AS status_code_id,
        TRIM(ENTITY_TYPE) AS entity_type,
        TRIM(STATUS_CODE) AS status_code,
        TRIM(STATUS_NAME) AS status_name,
        TRIM(STATUS_DESCRIPTION) AS status_description,
        COALESCE(DISPLAY_ORDER, 0) AS display_order,
        IS_TERMINAL AS is_terminal,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE STATUS_CODE_ID IS NOT NULL
)

SELECT * FROM renamed
