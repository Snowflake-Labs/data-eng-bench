{{
    config(
        materialized='view',
        
        tags=['staging', 'audit', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'AUDIT_LOGS') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY AUDIT_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(AUDIT_ID) AS audit_id,
        TRIM(EVENT_TYPE) AS event_type,
        EVENT_TIMESTAMP AS event_timestamp,
        TRIM(USER_ID) AS user_id,
        TRIM(USER_EMAIL) AS user_email,
        TRIM(TABLE_NAME) AS table_name,
        TRIM(RECORD_ID) AS record_id,
        TRIM(ACTION) AS action,
        OLD_VALUES AS old_values,
        NEW_VALUES AS new_values,
        TRIM(IP_ADDRESS) AS ip_address,
        TRIM(USER_AGENT) AS user_agent,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE AUDIT_ID IS NOT NULL
)

SELECT * FROM renamed
