{{
    config(
        materialized='view',
        
        tags=['staging', 'finance', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CUSTOMER_CREDITS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CREDIT_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CREDIT_ID) AS credit_id,
        TRIM(CREDIT_NUMBER) AS credit_number,
        TRIM(CUSTOMER_ID) AS customer_id,
        AMOUNT AS amount,
        COALESCE(BALANCE, 0) AS balance,
        TRIM(REASON) AS reason,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE CREDIT_ID IS NOT NULL
)

SELECT * FROM renamed
