{{
    config(
        materialized='view',

        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('inventory', 'INVENTORY_TRANSFER_LINES') }}

),

deduplicated AS (
    SELECT
        TRANSFER_LINE_ID,
        TRANSFER_ID,
        LINE_NUMBER,
        VARIANT_ID,
        SKU,
        QUANTITY_REQUESTED,
        QUANTITY_SHIPPED,
        QUANTITY_RECEIVED,
        QUANTITY_VARIANCE,
        UNIT_COST,
        LINE_VALUE,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TRANSFER_LINE_ID ORDER BY created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(TRANSFER_LINE_ID) AS transfer_line_id,
        TRIM(TRANSFER_ID) AS transfer_id,
        LINE_NUMBER AS line_number,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(SKU) AS sku,
        COALESCE(QUANTITY_REQUESTED, 0) AS quantity_requested,
        COALESCE(QUANTITY_SHIPPED, 0) AS quantity_shipped,
        COALESCE(QUANTITY_RECEIVED, 0) AS quantity_received,
        COALESCE(QUANTITY_VARIANCE, 0) AS quantity_variance,
        COALESCE(UNIT_COST, 0) AS unit_cost,
        COALESCE(LINE_VALUE, 0) AS line_value,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE TRANSFER_LINE_ID IS NOT NULL
)

SELECT * FROM renamed
