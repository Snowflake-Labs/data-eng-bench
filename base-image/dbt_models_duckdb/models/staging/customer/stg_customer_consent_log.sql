{{
    config(
        materialized='view',
        
        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('enterprise_db', 'CUSTOMER_CONSENT_LOG') }}
    
),

deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY CONSENT_ID ORDER BY created_at DESC) AS row_num
    FROM source
),

cleaned AS (
    SELECT * EXCLUDE (row_num) FROM deduplicated WHERE row_num = 1
),

renamed AS (
    SELECT
        TRIM(CONSENT_ID) AS consent_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(CONSENT_TYPE) AS consent_type,
        TRIM(CONSENT_VERSION) AS consent_version,
        IS_CONSENTED AS is_consented,
        TRIM(CONSENT_TEXT) AS consent_text,
        TRIM(IP_ADDRESS) AS ip_address,
        TRIM(USER_AGENT) AS user_agent,
        TRIM(CONSENT_SOURCE) AS consent_source,
        CONSENT_TIMESTAMP AS consent_timestamp,
        EXPIRY_DATE AS expiry_date,
        WITHDRAWN_AT AS withdrawn_at,
        TRIM(WITHDRAWAL_REASON) AS withdrawal_reason,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE CONSENT_ID IS NOT NULL
)

SELECT * FROM renamed
