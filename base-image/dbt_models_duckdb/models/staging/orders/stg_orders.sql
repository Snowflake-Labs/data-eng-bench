{{
    config(
        materialized='view',
        
        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'ORDERS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CHANNEL_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(ORDER_ID) AS order_id,
        TRIM(ORDER_NUMBER) AS order_number,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(ORDER_TYPE) AS order_type,
        TRIM(ORDER_SOURCE) AS order_source,
        TRIM(CHANNEL_ID) AS channel_id,
        TRIM(CURRENCY_CODE) AS currency_code,
        COALESCE(EXCHANGE_RATE, 0) AS exchange_rate,
        TRIM(BILLING_ADDRESS_ID) AS billing_address_id,
        TRIM(SHIPPING_ADDRESS_ID) AS shipping_address_id,
        SUBTOTAL AS subtotal,
        COALESCE(DISCOUNT_TOTAL, 0) AS discount_total,
        COALESCE(SHIPPING_TOTAL, 0) AS shipping_total,
        COALESCE(TAX_TOTAL, 0) AS tax_total,
        GRAND_TOTAL AS grand_total,
        TRIM(STATUS) AS status,
        TRIM(PAYMENT_STATUS) AS payment_status,
        TRIM(FULFILLMENT_STATUS) AS fulfillment_status,
        ORDERED_AT AS ordered_at,
        SHIPPED_AT AS shipped_at
    FROM cleaned
    WHERE CHANNEL_ID IS NOT NULL
)

SELECT * FROM renamed
