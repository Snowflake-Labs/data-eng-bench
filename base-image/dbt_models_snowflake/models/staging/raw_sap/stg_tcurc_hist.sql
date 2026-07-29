{{
    config(
        materialized='view',
        unique_key='_batch_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'TCURC_HIST') }}

),

cleaned AS (
    SELECT
        CURRENCY_CODE,
        CURRENCY_NAME,
        CURRENCY_SYMBOL,
        DECIMAL_PLACES,
        IS_ACTIVE,
        CREATED_AT,
        UPDATED_AT,
        _LOADED_AT,
        _SOURCE_SYSTEM,
        _BATCH_ID,
        _ROW_NUMBER,
        _ROW_HASH,
        "_archived_at",
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY _BATCH_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(CURRENCY_CODE) AS currency_code,
        TRIM(CURRENCY_NAME) AS currency_name,
        TRIM(CURRENCY_SYMBOL) AS currency_symbol,
        COALESCE(DECIMAL_PLACES, 0) AS decimal_places,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        "_archived_at" as _archived_at
    FROM cleaned
    WHERE _BATCH_ID IS NOT NULL
)

SELECT * FROM renamed
