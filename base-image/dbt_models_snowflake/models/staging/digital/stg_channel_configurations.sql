{{
    config(
        materialized='view',

        tags=['staging', 'digital', 'scaled']
    )
}}

WITH source AS (
    SELECT * FROM {{ source('digital', 'CHANNEL_CONFIGURATIONS') }}

),

deduplicated AS (
    SELECT
        CONFIG_ID,
        CHANNEL_ID,
        CONFIG_KEY,
        CONFIG_VALUE,
        CREATED_AT
    FROM source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CONFIG_ID ORDER BY created_at DESC NULLS LAST) = 1
),

renamed AS (
    SELECT
        TRIM(CONFIG_ID) AS config_id,
        TRIM(CHANNEL_ID) AS channel_id,
        TRIM(CONFIG_KEY) AS config_key,
        TRIM(CONFIG_VALUE) AS config_value,
        CREATED_AT AS created_at
    FROM deduplicated
    WHERE CONFIG_ID IS NOT NULL
)

SELECT * FROM renamed
