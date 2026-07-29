{{
    config(
        materialized='view',
        
        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'INVENTORY_TRANSFERS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY TRANSFER_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
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
        COALESCE(TOTAL_LINES, 0) AS total_lines,
        COALESCE(TOTAL_QUANTITY, 0) AS total_quantity,
        COALESCE(TOTAL_VALUE, 0) AS total_value,
        TRIM(CREATED_BY) AS created_by,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE TRANSFER_ID IS NOT NULL
)

SELECT * FROM renamed
