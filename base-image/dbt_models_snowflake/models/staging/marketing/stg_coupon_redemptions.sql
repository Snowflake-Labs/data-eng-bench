{{
    config(
        materialized='view',

        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('marketing', 'COUPON_REDEMPTIONS') }}

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
        COALESCE(DISCOUNT_AMOUNT, 0) as discount_amount,
        REDEEMED_AT AS redeemed_at
    FROM cleaned
    WHERE REDEMPTION_ID IS NOT NULL
)

SELECT * FROM renamed
