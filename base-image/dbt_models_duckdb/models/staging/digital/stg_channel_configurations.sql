{{
    config(
        materialized='view',
        
        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CHANNEL_CONFIGURATIONS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CONFIG_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CONFIG_ID) AS config_id,
        TRIM(CHANNEL_ID) AS channel_id,
        TRIM(CONFIG_KEY) AS config_key,
        TRIM(CONFIG_VALUE) AS config_value,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE CONFIG_ID IS NOT NULL
)

SELECT * FROM renamed
