{{
    config(
        materialized='view',
        
        tags=['staging', 'procurement', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'PURCHASE_CONTRACTS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CONTRACT_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CONTRACT_ID) AS contract_id,
        TRIM(CONTRACT_NUMBER) AS contract_number,
        TRIM(SUPPLIER_ID) AS supplier_id,
        TRIM(CONTRACT_TYPE) AS contract_type,
        START_DATE AS start_date,
        END_DATE AS end_date,
        COALESCE(TOTAL_VALUE, 0) AS total_value,
        TRIM(STATUS) AS status,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE CONTRACT_ID IS NOT NULL
)

SELECT * FROM renamed
