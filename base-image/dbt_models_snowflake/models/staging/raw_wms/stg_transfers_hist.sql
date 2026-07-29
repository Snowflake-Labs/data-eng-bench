{{
    config(
        materialized='view',

        tags=['staging', 'raw_wms', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_wms', 'transfers_hist') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY TRANSFER_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        TRANSFER_ID,
        TRANSFER_NUMBER,
        TRANSFER_TYPE,
        SOURCE_TYPE,
        SOURCE_WAREHOUSE_ID,
        SOURCE_STORE_ID,
        DEST_TYPE,
        DEST_WAREHOUSE_ID,
        DEST_STORE_ID,
        STATUS,
        PRIORITY,
        TOTAL_LINES,
        TOTAL_QUANTITY,
        TOTAL_VALUE,
        CREATED_BY,
        CREATED_AT,
        UPDATED_AT,
        _LOADED_AT,
        _SOURCE_SYSTEM,
        _BATCH_ID
    FROM deduplicated
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TRANSFER_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(TRANSFER_ID) AS transfer_id,
        TRIM(TRANSFER_NUMBER) AS transfer_number,
        TRIM(TRANSFER_TYPE) AS transfer_type,
        TRIM(SOURCE_TYPE) AS source_type,
        TRIM(SOURCE_WAREHOUSE_ID) AS source_warehouse_id,
        TRIM(SOURCE_STORE_ID) AS source_store_id,
        TRIM(DEST_TYPE) AS dest_type,
        TRIM(DEST_WAREHOUSE_ID) AS dest_warehouse_id,
        TRIM(DEST_STORE_ID) AS dest_store_id,
        TRIM(STATUS) AS status,
        TRIM(PRIORITY) AS priority,
        TRIM(TOTAL_LINES) AS total_lines,
        TRIM(TOTAL_QUANTITY) AS total_quantity,
        TRIM(TOTAL_VALUE) AS total_value,
        TRIM(CREATED_BY) AS created_by,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id
    FROM cleaned
    WHERE TRANSFER_ID IS NOT NULL
)

SELECT * FROM renamed
