{{
    config(
        materialized='view',
        
        tags=['staging', 'raw_legacy', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'STSCOD') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY STATUS_CODE_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
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
