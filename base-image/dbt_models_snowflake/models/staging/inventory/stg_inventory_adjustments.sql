{{
    config(
        materialized='view',

        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('inventory', 'INVENTORY_ADJUSTMENTS') }}

),

cleaned AS (
    SELECT
        ADJUSTMENT_ID,
        ADJUSTMENT_NUMBER,
        WAREHOUSE_ID,
        ADJUSTMENT_TYPE,
        STATUS,
        TOTAL_LINES,
        TOTAL_QUANTITY,
        TOTAL_VALUE,
        REASON_CODE,
        NOTES,
        REQUESTED_BY,
        REQUESTED_AT,
        APPROVED_BY,
        created_at,
        updated_at
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ADJUSTMENT_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(ADJUSTMENT_ID) AS adjustment_id,
        TRIM(ADJUSTMENT_NUMBER) AS adjustment_number,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        TRIM(ADJUSTMENT_TYPE) AS adjustment_type,
        TRIM(STATUS) AS status,
        COALESCE(TOTAL_LINES, 0) AS total_lines,
        COALESCE(TOTAL_QUANTITY, 0) AS total_quantity,
        COALESCE(TOTAL_VALUE, 0) AS total_value,
        TRIM(REASON_CODE) AS reason_code,
        TRIM(NOTES) AS notes,
        TRIM(REQUESTED_BY) AS requested_by,
        REQUESTED_AT AS requested_at,
        TRIM(APPROVED_BY) AS approved_by,
        created_at AS created_at,
        updated_at AS updated_at
    FROM cleaned
    WHERE ADJUSTMENT_ID IS NOT NULL
)

SELECT * FROM renamed
