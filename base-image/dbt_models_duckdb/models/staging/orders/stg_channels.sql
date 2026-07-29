{{
    config(
        materialized='view',
        
        tags=['staging', 'orders', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CHANNELS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CHANNEL_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CHANNEL_ID) AS channel_id,
        TRIM(CHANNEL_CODE) AS channel_code,
        TRIM(CHANNEL_NAME) AS channel_name,
        TRIM(CHANNEL_TYPE) AS channel_type,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE CHANNEL_ID IS NOT NULL
)

SELECT * FROM renamed
