{{
    config(
        materialized='view',

        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('finance', 'CUSTOMER_AGING') }}

),

deduplicated AS (
    SELECT
        AGING_ID,
        CUSTOMER_ID,
        AS_OF_DATE,
        CURRENT_AMOUNT,
        DAYS_30_AMOUNT,
        DAYS_60_AMOUNT,
        DAYS_90_AMOUNT,
        OVER_90_AMOUNT,
        TOTAL_BALANCE,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY AGING_ID ORDER BY created_at DESC NULLS LAST) = 1
),

cleaned AS (
    SELECT * FROM deduplicated
),

renamed AS (
    SELECT
        TRIM(AGING_ID) AS aging_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        AS_OF_DATE AS as_of_date,
        COALESCE(CURRENT_AMOUNT, 0) AS current_amount,
        COALESCE(DAYS_30_AMOUNT, 0) AS days_30_amount,
        COALESCE(DAYS_60_AMOUNT, 0) AS days_60_amount,
        COALESCE(DAYS_90_AMOUNT, 0) AS days_90_amount,
        COALESCE(OVER_90_AMOUNT, 0) AS over_90_amount,
        COALESCE(TOTAL_BALANCE, 0) AS total_balance,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE AGING_ID IS NOT NULL
)

SELECT * FROM renamed
