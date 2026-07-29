{{
    config(
        materialized='view',

        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('inventory', 'REORDER_RULES') }}

),

deduplicated AS (
    SELECT
        RULE_ID,
        VARIANT_ID,
        WAREHOUSE_ID,
        MIN_QUANTITY,
        MAX_QUANTITY,
        REORDER_POINT,
        REORDER_QUANTITY,
        LEAD_TIME_DAYS,
        SAFETY_STOCK,
        REPLENISHMENT_METHOD,
        IS_ACTIVE,
        EFFECTIVE_FROM,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY RULE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(RULE_ID) AS rule_id,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        COALESCE(MIN_QUANTITY, 0) AS min_quantity,
        COALESCE(MAX_QUANTITY, 0) AS max_quantity,
        COALESCE(REORDER_POINT, 0) AS reorder_point,
        COALESCE(REORDER_QUANTITY, 0) AS reorder_quantity,
        COALESCE(LEAD_TIME_DAYS, 0) AS lead_time_days,
        COALESCE(SAFETY_STOCK, 0) AS safety_stock,
        TRIM(REPLENISHMENT_METHOD) AS replenishment_method,
        IS_ACTIVE AS is_active,
        EFFECTIVE_FROM AS effective_from,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE RULE_ID IS NOT NULL
)

SELECT * FROM renamed
