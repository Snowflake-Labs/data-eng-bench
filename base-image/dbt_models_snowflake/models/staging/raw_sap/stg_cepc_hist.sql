{{
    config(
        materialized='view',
        unique_key='profit_center_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('sap', 'CEPC_HIST') }}

),

renamed AS (
    SELECT
        TRIM(PROFIT_CENTER_ID) AS profit_center_id,
        TRIM(PROFIT_CENTER_CODE) AS profit_center_code,
        TRIM(PROFIT_CENTER_NAME) AS profit_center_name,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        "_archived_at" as _archived_at
    FROM source
    WHERE PROFIT_CENTER_ID IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PROFIT_CENTER_ID ORDER BY created_at DESC NULLS LAST) = 1
)

SELECT * FROM renamed
