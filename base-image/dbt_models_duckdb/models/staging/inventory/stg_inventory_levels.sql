{{
    config(
        materialized='view',
        
        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'INVENTORY_LEVELS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY INVENTORY_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(INVENTORY_ID) AS inventory_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(LOCATION_TYPE) AS location_type,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        TRIM(STORE_ID) AS store_id,
        TRIM(LOCATION_ID) AS location_id,
        QUANTITY_ON_HAND AS quantity_on_hand,
        QUANTITY_AVAILABLE AS quantity_available,
        COALESCE(QUANTITY_RESERVED, 0) AS quantity_reserved,
        COALESCE(QUANTITY_INCOMING, 0) AS quantity_incoming,
        COALESCE(QUANTITY_ON_HOLD, 0) AS quantity_on_hold,
        COALESCE(UNIT_COST, 0) AS unit_cost,
        TRIM(INVENTORY_STATUS) AS inventory_status,
        LAST_COUNTED_AT AS last_counted_at,
        LAST_RECEIVED_AT AS last_received_at,
        LAST_PICKED_AT AS last_picked_at,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE INVENTORY_ID IS NOT NULL
)

SELECT * FROM renamed
