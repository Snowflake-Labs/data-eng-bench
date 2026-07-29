{{
    config(
        materialized='view',
        
        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'SHIPMENT_PACKAGES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PACKAGE_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PACKAGE_ID) AS package_id,
        TRIM(SHIPMENT_ID) AS shipment_id,
        COALESCE(PACKAGE_NUMBER, 0) AS package_number,
        TRIM(TRACKING_NUMBER) AS tracking_number,
        COALESCE(WEIGHT, 0) AS weight,
        COALESCE(LENGTH, 0) AS length,
        COALESCE(WIDTH, 0) AS width,
        COALESCE(HEIGHT, 0) AS height,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE PACKAGE_ID IS NOT NULL
)

SELECT * FROM renamed
