{{
    config(
        materialized='view',
        
        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'SHIPMENT_TRACKING') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY TRACKING_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(TRACKING_ID) AS tracking_id,
        TRIM(SHIPMENT_ID) AS shipment_id,
        TRIM(STATUS) AS status,
        TRIM(LOCATION) AS location,
        TRIM(DESCRIPTION) AS description,
        TRACKED_AT AS tracked_at,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE TRACKING_ID IS NOT NULL
)

SELECT * FROM renamed
