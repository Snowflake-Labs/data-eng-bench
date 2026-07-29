{{
    config(
        materialized='view',

        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('inventory', 'INVENTORY_ADJUSTMENT_LINES') }}

),

cleaned AS (
    SELECT
        ADJUSTMENT_LINE_ID,
        ADJUSTMENT_ID,
        LINE_NUMBER,
        VARIANT_ID,
        SKU,
        QUANTITY_BEFORE,
        QUANTITY_ADJUSTMENT,
        QUANTITY_AFTER,
        UNIT_COST,
        ADJUSTMENT_VALUE,
        created_at
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ADJUSTMENT_LINE_ID ORDER BY created_at DESC NULLS LAST) = 1
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
        created_at AS created_at
    FROM cleaned
    WHERE ADJUSTMENT_LINE_ID IS NOT NULL
)

SELECT * FROM renamed
