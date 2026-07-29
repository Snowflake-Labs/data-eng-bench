{{
    config(
        materialized='view',
        
        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'SHIPMENT_LINES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY SHIPMENT_LINE_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(SHIPMENT_LINE_ID) AS shipment_line_id,
        TRIM(SHIPMENT_ID) AS shipment_id,
        TRIM(ORDER_LINE_ID) AS order_line_id,
        QUANTITY_SHIPPED AS quantity_shipped,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE SHIPMENT_LINE_ID IS NOT NULL
)

SELECT * FROM renamed
