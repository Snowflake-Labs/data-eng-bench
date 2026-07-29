{{
    config(
        materialized='view',
        unique_key='po_id',
        tags=['staging', 'raw_sap', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'EKKO_HIST') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PO_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
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
        _archived_at AS _archived_at
    FROM cleaned
    WHERE PO_ID IS NOT NULL
)

SELECT * FROM renamed
