{{
    config(
        materialized='view',

        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('procurement', 'SUPPLIERS') }}

),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY SUPPLIER_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        SUPPLIER_ID,
        SUPPLIER_CODE,
        SUPPLIER_NAME,
        SUPPLIER_TYPE,
        TAX_ID,
        DUNS_NUMBER,
        PAYMENT_TERMS,
        CURRENCY_CODE,
        LEAD_TIME_DAYS,
        MIN_ORDER_VALUE,
        RATING,
        STATUS,
        CREATED_AT,
        UPDATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(SUPPLIER_ID) AS supplier_id,
        TRIM(SUPPLIER_CODE) AS supplier_code,
        TRIM(SUPPLIER_NAME) AS supplier_name,
        TRIM(SUPPLIER_TYPE) AS supplier_type,
        TRIM(TAX_ID) AS tax_id,
        TRIM(DUNS_NUMBER) AS duns_number,
        TRIM(PAYMENT_TERMS) AS payment_terms,
        TRIM(CURRENCY_CODE) AS currency_code,
        COALESCE(LEAD_TIME_DAYS, 0) AS lead_time_days,
        COALESCE(MIN_ORDER_VALUE, 0) AS min_order_value,
        COALESCE(RATING, 0) AS rating,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE SUPPLIER_ID IS NOT NULL
)

SELECT * FROM renamed
