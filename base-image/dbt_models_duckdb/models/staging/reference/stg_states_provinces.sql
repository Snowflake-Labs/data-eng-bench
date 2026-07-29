{{
    config(
        materialized='view',
        
        tags=['staging', 'reference', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'STATES_PROVINCES') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY STATE_PROVINCE_ID ORDER BY updated_at DESC, created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(STATE_PROVINCE_ID) AS state_province_id,
        TRIM(COUNTRY_ID) AS country_id,
        TRIM(STATE_CODE) AS state_code,
        TRIM(STATE_NAME) AS state_name,
        IS_ACTIVE AS is_active,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM cleaned
    WHERE STATE_PROVINCE_ID IS NOT NULL
)

SELECT * FROM renamed
