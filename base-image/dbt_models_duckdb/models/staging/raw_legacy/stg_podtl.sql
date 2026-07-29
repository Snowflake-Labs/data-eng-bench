{{
    config(
        materialized='view',
        
        tags=['staging', 'raw_legacy', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PODTL') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PO_LINE_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PO_LINE_ID) AS po_line_id,
        TRIM(PO_ID) AS po_id,
        COALESCE(LINE_NUMBER, 0) AS line_number,
        TRIM(VARIANT_ID) AS variant_id,
        TRIM(SKU) AS sku,
        COALESCE(QUANTITY_ORDERED, 0) AS quantity_ordered,
        COALESCE(QUANTITY_RECEIVED, 0) AS quantity_received,
        TRIM(UNIT_PRICE) AS unit_price,
        TRIM(LINE_TOTAL) AS line_total,
        CREATED_AT AS created_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE PO_LINE_ID IS NOT NULL
)

SELECT * FROM renamed
