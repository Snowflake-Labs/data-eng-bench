{{
    config(
        materialized='view',
        
        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'INVENTORY_COUNT_DETAILS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY COUNT_DETAIL_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(COUNT_DETAIL_ID) AS count_detail_id,
        TRIM(COUNT_ID) AS count_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(SKU) AS sku,
        COALESCE(SYSTEM_QUANTITY, 0) AS system_quantity,
        COALESCE(COUNTED_QUANTITY, 0) AS counted_quantity,
        COALESCE(VARIANCE_QUANTITY, 0) AS variance_quantity,
        COALESCE(UNIT_COST, 0) AS unit_cost,
        COALESCE(VARIANCE_VALUE, 0) AS variance_value,
        TRIM(COUNT_STATUS) AS count_status,
        TRIM(COUNTED_BY) AS counted_by,
        COUNTED_AT AS counted_at,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE COUNT_DETAIL_ID IS NOT NULL
)

SELECT * FROM renamed
