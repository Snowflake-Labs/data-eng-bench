{{
    config(
        materialized='view',
        
        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CUSTOMER_PAYMENTS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY PAYMENT_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(PAYMENT_ID) AS payment_id,
        TRIM(PAYMENT_NUMBER) AS payment_number,
        TRIM(CUSTOMER_ID) AS customer_id,
        PAYMENT_DATE AS payment_date,
        AMOUNT AS amount,
        TRIM(PAYMENT_METHOD) AS payment_method,
        TRIM(REFERENCE_NUMBER) AS reference_number,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE PAYMENT_ID IS NOT NULL
)

SELECT * FROM renamed
