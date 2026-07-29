{{
    config(
        materialized='view',

        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('procurement', 'PURCHASE_ORDERS') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PO_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        PO_ID,
        PO_NUMBER,
        SUPPLIER_ID,
        WAREHOUSE_ID,
        STATUS,
        TOTAL_AMOUNT,
        CURRENCY_CODE,
        EXPECTED_DATE,
        ORDERED_AT,
        CREATED_BY,
        CREATED_AT,
        UPDATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PO_ID) AS po_id,
        TRIM(PO_NUMBER) AS po_number,
        TRIM(SUPPLIER_ID) AS supplier_id,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        TRIM(STATUS) AS status,
        COALESCE(TOTAL_AMOUNT, 0) AS total_amount,
        TRIM(CURRENCY_CODE) AS currency_code,
        EXPECTED_DATE AS expected_date,
        ORDERED_AT AS ordered_at,
        TRIM(CREATED_BY) AS created_by,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE PO_ID IS NOT NULL
)

SELECT * FROM renamed
