{{
    config(
        materialized='view',

        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('inventory', 'INVENTORY_SNAPSHOTS') }}

),

deduplicated AS (
    SELECT
        SNAPSHOT_ID,
        SNAPSHOT_DATE,
        VARIANT_ID,
        WAREHOUSE_ID,
        QUANTITY_ON_HAND,
        QUANTITY_AVAILABLE,
        QUANTITY_RESERVED,
        QUANTITY_INCOMING,
        UNIT_COST,
        TOTAL_VALUE,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY SNAPSHOT_ID ORDER BY created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(SNAPSHOT_ID) AS snapshot_id,
        SNAPSHOT_DATE AS snapshot_date,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        COALESCE(QUANTITY_ON_HAND, 0) AS quantity_on_hand,
        COALESCE(QUANTITY_AVAILABLE, 0) AS quantity_available,
        COALESCE(QUANTITY_RESERVED, 0) AS quantity_reserved,
        COALESCE(QUANTITY_INCOMING, 0) AS quantity_incoming,
        COALESCE(UNIT_COST, 0) AS unit_cost,
        COALESCE(TOTAL_VALUE, 0) AS total_value,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE SNAPSHOT_ID IS NOT NULL
)

SELECT * FROM renamed
