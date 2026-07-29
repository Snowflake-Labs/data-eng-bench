{{
    config(
        materialized='view',

        tags=['staging', 'inventory', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('inventory', 'INVENTORY_TRANSACTIONS') }}

),

deduplicated AS (
    SELECT
        TRANSACTION_ID,
        VARIANT_ID,
        WAREHOUSE_ID,
        TRANSACTION_TYPE,
        QUANTITY,
        UOM,
        QUANTITY_BEFORE,
        QUANTITY_AFTER,
        UNIT_COST,
        REFERENCE_TYPE,
        REFERENCE_NUMBER,
        TRANSACTION_DATE,
        TRANSACTION_TIMESTAMP,
        CREATED_BY,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY TRANSACTION_ID ORDER BY created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
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
