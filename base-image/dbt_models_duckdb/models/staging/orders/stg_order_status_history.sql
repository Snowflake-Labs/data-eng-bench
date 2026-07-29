{{
    config(
        materialized='view',
        
        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'ORDER_STATUS_HISTORY') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(HISTORY_ID) AS history_id,
        TRIM(ORDER_ID) AS order_id,
        TRIM(OLD_STATUS) AS old_status,
        TRIM(NEW_STATUS) AS new_status,
        TRIM(CHANGED_BY) AS changed_by,
        TRIM(CHANGE_REASON) AS change_reason,
        TRIM(NOTES) AS notes,
        CHANGED_AT AS changed_at
    FROM cleaned
    WHERE HISTORY_ID IS NOT NULL
)

SELECT * FROM renamed
