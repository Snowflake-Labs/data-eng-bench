{{
    config(
        materialized='view',

        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('marketing', 'LOYALTY_POINTS_TRANSACTIONS') }}

),

deduplicated AS (
    SELECT
        TRANSACTION_ID,
        CUSTOMER_ID,
        PROGRAM_ID,
        TRANSACTION_TYPE,
        POINTS,
        BALANCE_AFTER,
        ORDER_ID,
        DESCRIPTION,
        EXPIRES_AT,
        CREATED_AT,
        ROW_NUMBER() OVER (PARTITION BY TRANSACTION_ID ORDER BY created_at DESC NULLS LAST) AS row_num
    FROM source
),

cleaned AS (
    SELECT
        TRANSACTION_ID,
        CUSTOMER_ID,
        PROGRAM_ID,
        TRANSACTION_TYPE,
        POINTS,
        BALANCE_AFTER,
        ORDER_ID,
        DESCRIPTION,
        EXPIRES_AT,
        CREATED_AT
    FROM deduplicated
    WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(TRANSACTION_ID) AS transaction_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(PROGRAM_ID) AS program_id,
        TRIM(TRANSACTION_TYPE) AS transaction_type, POINTS as points,
        COALESCE(BALANCE_AFTER, 0) as balance_after,
        TRIM(ORDER_ID) AS order_id,
        TRIM(DESCRIPTION) AS description,
        EXPIRES_AT AS expires_at,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE TRANSACTION_ID IS NOT NULL
)

SELECT * FROM renamed
