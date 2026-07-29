{{
    config(
        materialized='view',
        
        tags=['staging', 'analytics', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'DIM_CHANNEL') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        CHANNEL_KEY AS channel_key,
        TRIM(CHANNEL_ID) AS channel_id,
        TRIM(CHANNEL_CODE) AS channel_code,
        TRIM(CHANNEL_NAME) AS channel_name,
        TRIM(CHANNEL_TYPE) AS channel_type,
        IS_ACTIVE AS is_active
    FROM cleaned
    WHERE CHANNEL_ID IS NOT NULL
)

SELECT * FROM renamed
