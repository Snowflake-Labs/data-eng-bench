{{
    config(
        materialized='view',

        tags=['staging', 'customer', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('customer', 'CUSTOMER_PREFERENCES') }}

),

deduplicated AS (
    SELECT
        PREFERENCE_ID,
        CUSTOMER_ID,
        PREFERENCE_CATEGORY,
        PREFERENCE_KEY,
        PREFERENCE_VALUE,
        IS_OPTED_IN,
        EFFECTIVE_FROM,
        EFFECTIVE_TO,
        SOURCE,
        CREATED_AT,
        UPDATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PREFERENCE_ID ORDER BY updated_at DESC NULLS LAST, created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(PREFERENCE_ID) AS preference_id,
        TRIM(CUSTOMER_ID) AS customer_id,
        TRIM(PREFERENCE_CATEGORY) AS preference_category,
        TRIM(PREFERENCE_KEY) AS preference_key,
        TRIM(PREFERENCE_VALUE) AS preference_value,
        IS_OPTED_IN as is_opted_in,
        EFFECTIVE_FROM AS effective_from,
        EFFECTIVE_TO AS effective_to,
        TRIM(SOURCE) AS source,
        CREATED_AT AS created_at,
        UPDATED_AT AS updated_at
    FROM deduplicated
    WHERE PREFERENCE_ID IS NOT NULL
)

SELECT * FROM renamed
