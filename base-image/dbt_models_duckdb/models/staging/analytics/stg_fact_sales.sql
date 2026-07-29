{{
    config(
        materialized='view',
        
        tags=['staging', 'analytics', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'FACT_SALES') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(SALE_KEY) AS sale_key,
        DATE_KEY AS date_key,
        COALESCE(TIME_KEY, 0) AS time_key,
        COALESCE(CUSTOMER_KEY, 0) AS customer_key,
        COALESCE(PRODUCT_KEY, 0) AS product_key,
        COALESCE(EMPLOYEE_KEY, 0) AS employee_key,
        COALESCE(CHANNEL_KEY, 0) AS channel_key,
        COALESCE(GEOGRAPHY_KEY, 0) AS geography_key,
        TRIM(ORDER_ID) AS order_id,
        TRIM(ORDER_LINE_ID) AS order_line_id,
        COALESCE(QUANTITY, 0) AS quantity,
        COALESCE(UNIT_PRICE, 0) AS unit_price,
        COALESCE(DISCOUNT_AMOUNT, 0) AS discount_amount,
        COALESCE(TAX_AMOUNT, 0) AS tax_amount,
        COALESCE(TOTAL_AMOUNT, 0) AS total_amount,
        COALESCE(COST_AMOUNT, 0) AS cost_amount,
        COALESCE(PROFIT_AMOUNT, 0) AS profit_amount
    FROM cleaned
    WHERE SALE_KEY IS NOT NULL
)

SELECT * FROM renamed
