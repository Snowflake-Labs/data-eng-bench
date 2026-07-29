{{
    config(
        materialized='view',
        unique_key='_batch_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'T006') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY _BATCH_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(UOM_CODE) AS uom_code,
        TRIM(UOM_NAME) AS uom_name,
        TRIM(UOM_TYPE) AS uom_type,
        TRIM(BASE_UOM_CODE) AS base_uom_code,
        CONVERSION_FACTOR AS conversion_factor,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE _BATCH_ID IS NOT NULL
)

SELECT * FROM renamed
