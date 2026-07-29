{{
    config(
        materialized='view',
        
        tags=['staging', 'marketing', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'LOYALTY_POINTS_TRANSACTIONS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY TRANSACTION_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(TRANSACTION_ID) AS transaction_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(PROGRAM_ID) AS program_id,
        TRIM(TRANSACTION_TYPE) AS transaction_type,
        POINTS AS points,
        COALESCE(BALANCE_AFTER, 0) AS balance_after,
        TRIM(ORDER_ID) AS order_id,
        TRIM(DESCRIPTION) AS description,
        EXPIRES_AT AS expires_at,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE TRANSACTION_ID IS NOT NULL
)

SELECT * FROM renamed
