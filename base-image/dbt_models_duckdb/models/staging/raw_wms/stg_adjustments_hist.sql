{{
    config(
        materialized='view',
        
        tags=['staging', 'raw_wms', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'ADJUSTMENTS_HIST') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY ADJUSTMENT_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(ADJUSTMENT_ID) AS adjustment_id,
        TRIM(ADJUSTMENT_NUMBER) AS adjustment_number,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        TRIM(ADJUSTMENT_TYPE) AS adjustment_type,
        TRIM(STATUS) AS status,
        TRIM(TOTAL_LINES) AS total_lines,
        TRIM(TOTAL_QUANTITY) AS total_quantity,
        TRIM(TOTAL_VALUE) AS total_value,
        TRIM(REASON_CODE) AS reason_code,
        TRIM(NOTES) AS notes,
        TRIM(REQUESTED_BY) AS requested_by,
        REQUESTED_AT AS requested_at,
        TRIM(APPROVED_BY) AS approved_by,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE ADJUSTMENT_ID IS NOT NULL
)

SELECT * FROM renamed
