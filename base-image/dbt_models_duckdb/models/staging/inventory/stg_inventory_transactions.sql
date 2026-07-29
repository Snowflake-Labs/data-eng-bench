{{
    config(
        materialized='view',
        
        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'INVENTORY_TRANSACTIONS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY TRANSACTION_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(TRANSACTION_ID) AS transaction_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        TRIM(TRANSACTION_TYPE) AS transaction_type,
        QUANTITY AS quantity,
        TRIM(UOM) AS uom,
        COALESCE(QUANTITY_BEFORE, 0) AS quantity_before,
        COALESCE(QUANTITY_AFTER, 0) AS quantity_after,
        COALESCE(UNIT_COST, 0) AS unit_cost,
        TRIM(REFERENCE_TYPE) AS reference_type,
        TRIM(REFERENCE_NUMBER) AS reference_number,
        TRANSACTION_DATE AS transaction_date,
        TRANSACTION_TIMESTAMP AS transaction_timestamp,
        TRIM(CREATED_BY) AS created_by,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE TRANSACTION_ID IS NOT NULL
)

SELECT * FROM renamed
