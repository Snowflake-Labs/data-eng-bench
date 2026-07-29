{{
    config(
        materialized='view',
        
        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PURCHASE_CONTRACT_ITEMS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY ITEM_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(ITEM_ID) AS item_id,
        TRIM(CONTRACT_ID) AS contract_id,
        TRIM(VARIANT_ID) AS variant_id,
        COALESCE(UNIT_PRICE, 0) AS unit_price,
        COALESCE(MIN_QUANTITY, 0) AS min_quantity,
        COALESCE(MAX_QUANTITY, 0) AS max_quantity,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE ITEM_ID IS NOT NULL
)

SELECT * FROM renamed
