{{
    config(
        materialized='view',

        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('inventory', 'INVENTORY_LEVELS') }}

),

cleaned AS (
    SELECT
        INVENTORY_ID,
        VARIANT_ID,
        LOCATION_TYPE,
        WAREHOUSE_ID,
        STORE_ID,
        LOCATION_ID,
        QUANTITY_ON_HAND,
        QUANTITY_AVAILABLE,
        QUANTITY_RESERVED,
        QUANTITY_INCOMING,
        QUANTITY_ON_HOLD,
        UNIT_COST,
        INVENTORY_STATUS,
        LAST_COUNTED_AT,
        LAST_RECEIVED_AT,
        LAST_PICKED_AT,
        created_at,
        updated_at
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY INVENTORY_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
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
        created_at AS created_at,
        updated_at AS updated_at
    FROM cleaned
    WHERE INVENTORY_ID IS NOT NULL
)

SELECT * FROM renamed
