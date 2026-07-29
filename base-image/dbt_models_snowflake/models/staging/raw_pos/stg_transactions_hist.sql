{{
    config(
        materialized='view',

        tags=['staging', 'raw_pos', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('raw_pos', 'transactions_hist') }}

),

deduplicated AS (
    SELECT *
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CHANNEL_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(ORDER_ID) AS order_id,
        trim(ORDER_NUMBER) as order_number,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(ORDER_TYPE) AS order_type,
        TRIM(ORDER_SOURCE) AS order_source,
        TRIM(CHANNEL_ID) AS channel_id,
        TRIM(CURRENCY_CODE) AS currency_code,
        COALESCE(EXCHANGE_RATE, 0) as exchange_rate,
        TRIM(BILLING_ADDRESS_ID) AS billing_address_id,
        TRIM(SHIPPING_ADDRESS_ID) AS shipping_address_id,
        TRIM(SUBTOTAL) AS subtotal,
        TRIM(DISCOUNT_TOTAL) AS discount_total,
        TRIM(SHIPPING_TOTAL) AS shipping_total,
        TRIM(TAX_TOTAL) AS tax_total,
        TRIM(GRAND_TOTAL) AS grand_total,
        TRIM(STATUS) AS status,
        TRIM(PAYMENT_STATUS) AS payment_status,
        TRIM(FULFILLMENT_STATUS) AS fulfillment_status,
        ORDERED_AT AS ordered_at,
        SHIPPED_AT AS shipped_at
    FROM cleaned
    WHERE CHANNEL_ID IS NOT NULL
)

SELECT * FROM renamed
