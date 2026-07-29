{{
    config(
        materialized='view',
        
        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'ORDER_CANCELLATIONS') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(CANCELLATION_ID) AS cancellation_id,
        TRIM(ORDER_ID) AS order_id,
        TRIM(REASON_CODE) AS reason_code,
        TRIM(REASON_TEXT) AS reason_text,
        TRIM(CANCELLED_BY) AS cancelled_by,
        CANCELLED_AT AS cancelled_at,
        COALESCE(REFUND_AMOUNT, 0) AS refund_amount
    FROM cleaned
    WHERE CANCELLATION_ID IS NOT NULL
)

SELECT * FROM renamed
