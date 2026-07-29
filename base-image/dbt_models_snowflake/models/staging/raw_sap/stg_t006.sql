{{
    config(
        materialized='view',
        unique_key='_batch_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'T006') }}

),

cleaned AS (
    SELECT
        UOM_CODE,
        UOM_NAME,
        UOM_TYPE,
        BASE_UOM_CODE,
        CONVERSION_FACTOR,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT,
        _LOADED_AT,
        _SOURCE_SYSTEM,
        _BATCH_ID,
        _ROW_NUMBER,
        _ROW_HASH
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY _BATCH_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(UOM_CODE) AS uom_code,
        TRIM(UOM_NAME) AS uom_name,
        TRIM(UOM_TYPE) AS uom_type,
        TRIM(BASE_UOM_CODE) AS base_uom_code,
        CONVERSION_FACTOR as conversion_factor,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) as _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE _BATCH_ID IS NOT NULL
)

SELECT * FROM renamed
