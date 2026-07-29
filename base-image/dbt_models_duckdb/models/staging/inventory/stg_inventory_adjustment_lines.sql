{{
    config(
        materialized='view',
        
        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'INVENTORY_ADJUSTMENT_LINES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY ADJUSTMENT_LINE_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(ADJUSTMENT_LINE_ID) AS adjustment_line_id,
        TRIM(ADJUSTMENT_ID) AS adjustment_id,
        LINE_NUMBER AS line_number,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(SKU) AS sku,
        COALESCE(QUANTITY_BEFORE, 0) AS quantity_before,
        COALESCE(QUANTITY_ADJUSTMENT, 0) AS quantity_adjustment,
        COALESCE(QUANTITY_AFTER, 0) AS quantity_after,
        COALESCE(UNIT_COST, 0) AS unit_cost,
        COALESCE(ADJUSTMENT_VALUE, 0) AS adjustment_value,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE ADJUSTMENT_LINE_ID IS NOT NULL
)

SELECT * FROM renamed
