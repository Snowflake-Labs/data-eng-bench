{{
    config(
        materialized='view',

        tags=['staging', 'audit', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('customer', 'CONSENT_PREFERENCES') }}

),

cleaned AS (
    SELECT
        PREFERENCE_ID,
        CUSTOMER_ID,
        CONSENT_TYPE,
        IS_CONSENTED,
        CONSENT_DATE,
        IP_ADDRESS,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PREFERENCE_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(PREFERENCE_ID) AS preference_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(CONSENT_TYPE) AS consent_type,
        IS_CONSENTED AS is_consented,
        CONSENT_DATE AS consent_date,
        TRIM(IP_ADDRESS) AS ip_address,
        CREATED_AT AS created_at
    FROM cleaned
    WHERE PREFERENCE_ID IS NOT NULL
)

SELECT * FROM renamed
