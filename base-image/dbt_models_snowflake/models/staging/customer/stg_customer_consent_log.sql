{{
    config(
        materialized='view',

        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('customer', 'CUSTOMER_CONSENT_LOG') }}

),

deduplicated AS (
    SELECT
        CONSENT_ID,
        CUSTOMER_ID,
        CONSENT_TYPE,
        CONSENT_VERSION,
        IS_CONSENTED,
        CONSENT_TEXT,
        IP_ADDRESS,
        USER_AGENT,
        CONSENT_SOURCE,
        CONSENT_TIMESTAMP,
        EXPIRY_DATE,
        WITHDRAWN_AT,
        WITHDRAWAL_REASON,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CONSENT_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(CONSENT_ID) AS consent_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(CONSENT_TYPE) AS consent_type,
        trim(CONSENT_VERSION) as consent_version, IS_CONSENTED as is_consented,
        TRIM(CONSENT_TEXT) AS consent_text,
        TRIM(IP_ADDRESS) AS ip_address,
        TRIM(USER_AGENT) AS user_agent,
        TRIM(CONSENT_SOURCE) AS consent_source,
        CONSENT_TIMESTAMP AS consent_timestamp,
        EXPIRY_DATE AS expiry_date,
        WITHDRAWN_AT AS withdrawn_at,
        TRIM(WITHDRAWAL_REASON) AS withdrawal_reason,
        CREATED_AT AS created_at
    FROM deduplicated
    WHERE CONSENT_ID IS NOT NULL
)

SELECT * FROM renamed
