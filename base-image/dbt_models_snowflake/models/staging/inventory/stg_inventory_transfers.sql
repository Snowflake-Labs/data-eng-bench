{{
    config(
        materialized='view',

        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('inventory', 'INVENTORY_TRANSFERS') }}

),

deduplicated AS (
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
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TRANSFER_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
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
