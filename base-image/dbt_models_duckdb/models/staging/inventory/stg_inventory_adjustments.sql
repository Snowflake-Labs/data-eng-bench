{{
    config(
        materialized='view',
        
        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'INVENTORY_ADJUSTMENTS') }}
    
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
        COALESCE(TOTAL_LINES, 0) AS total_lines,
        COALESCE(TOTAL_QUANTITY, 0) AS total_quantity,
        COALESCE(TOTAL_VALUE, 0) AS total_value,
        TRIM(REASON_CODE) AS reason_code,
        TRIM(NOTES) AS notes,
        TRIM(REQUESTED_BY) AS requested_by,
        REQUESTED_AT AS requested_at,
        TRIM(APPROVED_BY) AS approved_by,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE ADJUSTMENT_ID IS NOT NULL
)

SELECT * FROM renamed
