{{
    config(
        materialized='view',
        
        tags=['staging', 'audit', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'USER_ACCESS_LOGS') }}
    
),

cleaned AS (
    SELECT * FROM source
),

renamed AS (
    SELECT
        TRIM(ACCESS_ID) AS access_id,
        TRIM(USER_ID) AS user_id,
        TRIM(USER_EMAIL) AS user_email,
        TRIM(ACCESS_TYPE) AS access_type,
        ACCESS_TIMESTAMP AS access_timestamp,
        TRIM(IP_ADDRESS) AS ip_address,
        TRIM(USER_AGENT) AS user_agent,
        TRIM(LOCATION) AS location,
        SUCCESS AS success,
        TRIM(FAILURE_REASON) AS failure_reason
    FROM cleaned
    WHERE ACCESS_ID IS NOT NULL
)

SELECT * FROM renamed
