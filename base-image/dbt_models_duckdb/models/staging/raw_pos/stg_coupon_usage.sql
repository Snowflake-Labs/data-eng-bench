{{
    config(
        materialized='view',
        
        tags=['staging', 'raw_pos', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'COUPON_USAGE') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(REDEMPTION_ID) AS redemption_id,
        TRIM(COUPON_ID) AS coupon_id,
        TRIM(ORDER_ID) AS order_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(DISCOUNT_AMOUNT) AS discount_amount,
        REDEEMED_AT AS redeemed_at,
        _LOADED_AT AS _loaded_at,
        TRIM(_SOURCE_SYSTEM) AS _source_system,
        TRIM(_BATCH_ID) AS _batch_id,
        TRIM(_ROW_NUMBER) AS _row_number,
        TRIM(_ROW_HASH) AS _row_hash
    FROM cleaned
    WHERE REDEMPTION_ID IS NOT NULL
)

SELECT * FROM renamed
