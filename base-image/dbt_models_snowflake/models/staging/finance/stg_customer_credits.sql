{{
    config(
        materialized='view',

        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('finance', 'CUSTOMER_CREDITS') }}

),

deduplicated AS (
    SELECT
        CREDIT_ID,
        CREDIT_NUMBER,
        CUSTOMER_ID,
        AMOUNT,
        BALANCE,
        REASON,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CREDIT_ID ORDER BY created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(CREDIT_ID) AS credit_id,
        TRIM(CREDIT_NUMBER) AS credit_number,
        TRIM(CUSTOMER_ID) AS customer_id, AMOUNT as amount,
        COALESCE(BALANCE, 0) as balance,
        TRIM(REASON) AS reason,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE CREDIT_ID IS NOT NULL
)

SELECT * FROM renamed
