{{
    config(
        materialized='view',

        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('finance', 'CUSTOMER_PAYMENTS') }}

),

deduplicated AS (
    SELECT
        PAYMENT_ID,
        PAYMENT_NUMBER,
        CUSTOMER_ID,
        PAYMENT_DATE,
        AMOUNT,
        PAYMENT_METHOD,
        REFERENCE_NUMBER,
        STATUS,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PAYMENT_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(PAYMENT_ID) AS payment_id,
        TRIM(PAYMENT_NUMBER) AS payment_number,
        TRIM(CUSTOMER_ID) AS customer_id,
        PAYMENT_DATE AS payment_date, AMOUNT as amount,
        TRIM(PAYMENT_METHOD) AS payment_method,
        TRIM(REFERENCE_NUMBER) AS reference_number,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at
    FROM deduplicated
    WHERE PAYMENT_ID IS NOT NULL
)

SELECT * FROM renamed
