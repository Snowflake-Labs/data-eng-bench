{{
    config(
        materialized='view',

        tags=['staging', 'raw_legacy', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_legacy', 'pohdr_stg') }}

),

deduplicated AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PO_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(PO_ID) AS po_id,
        TRIM(PO_NUMBER) AS po_number,
        TRIM(SUPPLIER_ID) AS supplier_id,
        TRIM(WAREHOUSE_ID) AS warehouse_id,
        TRIM(STATUS) AS status,
        TRIM(TOTAL_AMOUNT) AS total_amount,
        TRIM(CURRENCY_CODE) AS currency_code,
        EXPECTED_DATE AS expected_date,
        ORDERED_AT AS ordered_at,
        TRIM(CREATED_BY) AS created_by,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash,
        TRIM("_status") AS _status
    FROM deduplicated
    WHERE PO_ID IS NOT NULL
)

SELECT * FROM renamed
