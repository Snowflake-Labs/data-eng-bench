{{
    config(
        materialized='view',
        
        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'ORDER_HOLDS') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(HOLD_ID) AS hold_id,
        TRIM(ORDER_ID) AS order_id,
        TRIM(HOLD_TYPE) AS hold_type,
        TRIM(HOLD_REASON) AS hold_reason,
        TRIM(HOLD_STATUS) AS hold_status,
        TRIM(PLACED_BY) AS placed_by,
        PLACED_AT AS placed_at,
        TRIM(RELEASED_BY) AS released_by,
        RELEASED_AT AS released_at,
        TRIM(NOTES) AS notes
    FROM cleaned
    WHERE HOLD_ID IS NOT NULL
)

SELECT * FROM renamed
