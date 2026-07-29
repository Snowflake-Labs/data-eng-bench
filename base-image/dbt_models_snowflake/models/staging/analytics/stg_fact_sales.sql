{{
    config(
        materialized='view',

        tags=['staging', 'analytics', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('analytics', 'FACT_SALES') }}

),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(SALE_KEY) AS sale_key, DATE_KEY as date_key,
        COALESCE(TIME_KEY, 0) as time_key,
        COALESCE(CUSTOMER_KEY, 0) as customer_key,
        COALESCE(PRODUCT_KEY, 0) as product_key,
        COALESCE(EMPLOYEE_KEY, 0) as employee_key,
        COALESCE(CHANNEL_KEY, 0) as channel_key,
        COALESCE(GEOGRAPHY_KEY, 0) as geography_key,
        TRIM(ORDER_ID) AS order_id,
        TRIM(ORDER_LINE_ID) AS order_line_id,
        COALESCE(QUANTITY, 0) as quantity,
        COALESCE(UNIT_PRICE, 0) as unit_price,
        COALESCE(DISCOUNT_AMOUNT, 0) as discount_amount,
        COALESCE(TAX_AMOUNT, 0) as tax_amount,
        COALESCE(TOTAL_AMOUNT, 0) as total_amount,
        COALESCE(COST_AMOUNT, 0) as cost_amount,
        COALESCE(PROFIT_AMOUNT, 0) as profit_amount
    FROM cleaned
    WHERE SALE_KEY IS NOT NULL
)

SELECT * FROM renamed
