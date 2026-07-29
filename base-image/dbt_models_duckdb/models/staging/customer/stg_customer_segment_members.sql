{{
    config(
        materialized='view',
        
        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CUSTOMER_SEGMENT_MEMBERS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY MEMBERSHIP_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(MEMBERSHIP_ID) AS membership_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(SEGMENT_ID) AS segment_id,
        ADDED_DATE AS added_date,
        REMOVED_DATE AS removed_date,
        COALESCE(SCORE, 0) AS score,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE MEMBERSHIP_ID IS NOT NULL
)

SELECT * FROM renamed
